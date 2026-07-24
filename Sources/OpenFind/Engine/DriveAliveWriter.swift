import Darwin
import Foundation

protocol DriveAliveWriting: Sendable {
    func write(to directoryURL: URL, timeout: Duration) async throws
    func removeMarker(from directoryURL: URL, timeout: Duration) async throws
}

final class POSIXDriveAliveWriter: @unchecked Sendable, DriveAliveWriting {
    static let markerName = ".openfind-drive-alive"
    static let payloadSize = 2_048
    static let defaultTimeout: Duration = .seconds(10)

    private static let header = Data("OpenFind Drive Alive v1\n".utf8)
    private let operationLock = NSLock()
    private var activePaths: Set<String> = []
    private let syncFile: @Sendable (Int32) -> Int32
    private let operationScheduler: (@Sendable (@escaping @Sendable () -> Void) -> Void)?
    private let queue = DispatchQueue(label: "com.openfind.drive-alive", qos: .utility, attributes: .concurrent)

    init(
        syncFile: (@Sendable (Int32) -> Int32)? = nil,
        operationScheduler: (@Sendable (@escaping @Sendable () -> Void) -> Void)? = nil
    ) {
        self.syncFile = syncFile ?? { Darwin.fsync($0) }
        self.operationScheduler = operationScheduler
    }

    func write(to directoryURL: URL, timeout: Duration = defaultTimeout) async throws {
        try await runWithTimeout(for: directoryURL, timeout: timeout) {
            try self.writeSynchronously(to: directoryURL)
        }
    }

    func removeMarker(from directoryURL: URL, timeout: Duration = defaultTimeout) async throws {
        try await runWithTimeout(for: directoryURL, timeout: timeout) {
            try self.removeSynchronously(from: directoryURL)
        }
    }

    private func runWithTimeout(
        for directoryURL: URL,
        timeout: Duration,
        operation: @escaping @Sendable () throws -> Void
    ) async throws {
        guard timeout > .zero else { throw DriveAliveFailure.timedOut }
        guard directoryURL.isFileURL else { throw DriveAliveFailure.unsupportedTarget }
        let key = directoryURL.standardizedFileURL.path
        guard begin(path: key) else { throw DriveAliveFailure.writeAlreadyPending }

        let completion = DriveAliveWriteCompletion()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion.install(continuation)
                let work: @Sendable () -> Void = { [self] in
                    let result: Result<Void, Error>
                    do {
                        try operation()
                        result = .success(())
                    } catch {
                        result = .failure(error)
                    }
                    // Release the logical path before resuming the caller so a
                    // sequential write cannot observe a completed operation as
                    // still pending.
                    finish(path: key)
                    completion.resolve(result)
                }
                if let operationScheduler {
                    operationScheduler(work)
                } else {
                    queue.async(execute: work)
                }
                _ = Task.detached(priority: .utility) {
                    do {
                        try await Task.sleep(for: timeout)
                        completion.resolve(.failure(DriveAliveFailure.timedOut))
                    } catch {
                        // The timeout task is best effort; the write completion owns the result.
                    }
                }
            }
        } onCancel: {
            completion.resolve(.failure(CancellationError()))
        }
    }

    private func begin(path: String) -> Bool {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard activePaths.insert(path).inserted else { return false }
        return true
    }

    private func finish(path: String) {
        operationLock.lock()
        activePaths.remove(path)
        operationLock.unlock()
    }

    private func writeSynchronously(to directoryURL: URL) throws {
        let directoryPath = directoryURL.standardizedFileURL.path
        var directoryInfo = stat()
        guard stat(directoryPath, &directoryInfo) == 0 else {
            throw DriveAliveFailure.targetUnavailable
        }
        guard (directoryInfo.st_mode & S_IFMT) == S_IFDIR else {
            throw DriveAliveFailure.unsupportedTarget
        }

        let markerURL = directoryURL.appendingPathComponent(Self.markerName, isDirectory: false)
        let fd = try openMarker(markerURL.path)
        defer { _ = Darwin.close(fd.descriptor) }

        let isNew = fd.wasCreated
        if !isNew { try verifyExistingMarker(fd: fd.descriptor) }

        let payload = Self.makePayload()
        var offset: off_t = 0
        while offset < off_t(payload.count) {
            let written = payload.withUnsafeBytes { bytes -> Int in
                guard let base = bytes.baseAddress else { return -1 }
                return Darwin.pwrite(
                    fd.descriptor,
                    base.advanced(by: Int(offset)),
                    payload.count - Int(offset),
                    offset
                )
            }
            guard written > 0 else {
                if isNew { unlinkMarker(markerURL.path) }
                throw DriveAliveFailure.ioFailure(errno)
            }
            offset += off_t(written)
        }
        guard ftruncate(fd.descriptor, off_t(payload.count)) == 0 else {
            throw DriveAliveFailure.ioFailure(errno)
        }
        guard syncFile(fd.descriptor) == 0 else {
            throw DriveAliveFailure.ioFailure(errno)
        }
    }

    private func removeSynchronously(from directoryURL: URL) throws {
        let markerPath = directoryURL
            .standardizedFileURL
            .appendingPathComponent(Self.markerName, isDirectory: false)
            .path
        let fd: Int32
        do {
            fd = try openExistingMarker(markerPath)
        } catch let failure as DriveAliveFailure {
            if failure == .targetUnavailable { return }
            throw failure
        }
        defer { _ = Darwin.close(fd) }
        try verifyExistingMarker(fd: fd)
        guard unlink(markerPath) == 0 else { throw DriveAliveFailure.ioFailure(errno) }
    }

    private func verifyExistingMarker(fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw DriveAliveFailure.ioFailure(errno) }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw DriveAliveFailure.markerConflict }
        var header = [UInt8](repeating: 0, count: Self.header.count)
        let count = header.withUnsafeMutableBytes { bytes -> Int in
            guard let base = bytes.baseAddress else { return -1 }
            return Darwin.pread(fd, base, bytes.count, 0)
        }
        guard count == header.count, Data(header) == Self.header else {
            throw DriveAliveFailure.markerConflict
        }
    }

    private func openMarker(_ path: String) throws -> OpenedMarker {
        let flags = O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW
        let created = Darwin.open(path, flags, mode_t(S_IRUSR | S_IWUSR))
        if created >= 0 { return OpenedMarker(descriptor: created, wasCreated: true) }
        guard errno == EEXIST else { throw mapOpenError(errno) }
        return OpenedMarker(descriptor: try openExistingMarker(path), wasCreated: false)
    }

    private func openExistingMarker(_ path: String) throws -> Int32 {
        let descriptor = Darwin.open(path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw mapOpenError(errno) }
        return descriptor
    }

    private func mapOpenError(_ code: Int32) -> DriveAliveFailure {
        switch code {
        case EACCES, EPERM:
            return .permissionDenied
        case EROFS:
            return .readOnly
        case ENOENT, ENOTDIR:
            return .targetUnavailable
        case ELOOP:
            return .markerConflict
        default:
            return .ioFailure(code)
        }
    }

    private func unlinkMarker(_ path: String) {
        _ = unlink(path)
    }

    private static func makePayload() -> Data {
        var bytes = [UInt8](repeating: 0, count: payloadSize)
        header.copyBytes(to: &bytes, count: header.count)
        for index in header.count..<bytes.count {
            bytes[index] = UInt8.random(in: .min ... .max)
        }
        return Data(bytes)
    }
}

private struct OpenedMarker {
    let descriptor: Int32
    let wasCreated: Bool
}

private final class DriveAliveWriteCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var pendingResult: Result<Void, Error>?
    private var isResolved = false

    func install(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        if let pendingResult {
            self.pendingResult = nil
            lock.unlock()
            continuation.resume(with: pendingResult)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resolve(_ result: Result<Void, Error>) {
        lock.lock()
        guard !isResolved else {
            lock.unlock()
            return
        }
        isResolved = true
        guard let continuation else {
            pendingResult = result
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }
}

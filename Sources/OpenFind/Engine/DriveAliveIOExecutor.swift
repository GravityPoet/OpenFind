import Foundation

/// A timeout releases the caller, not a running filesystem syscall. The path
/// stays reserved until that syscall returns; queued, cancelled work never runs.
final class DriveAliveIOExecutor: @unchecked Sendable {
    private let lock = NSLock()
    private var active: [String: UUID] = [:]
    private let queue = DispatchQueue(label: "com.openfind.drive-alive.io", qos: .utility, attributes: .concurrent)
    private let schedule: (@Sendable (@escaping @Sendable () -> Void) -> Void)?

    init(schedule: (@Sendable (@escaping @Sendable () -> Void) -> Void)? = nil) {
        self.schedule = schedule
    }

    func run<Value: Sendable>(
        key: String,
        timeout: Duration,
        waitForPending: Bool = false,
        operation: @escaping @Sendable (DriveAliveIOCancellation) throws -> Value
    ) async throws -> Value {
        guard timeout > .zero else { throw DriveAliveFailure.timedOut }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        let id = UUID()
        while !claim(key, id: id) {
            guard waitForPending else { throw DriveAliveFailure.writeAlreadyPending }
            guard ContinuousClock.now < deadline else { throw DriveAliveFailure.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
        let state = DriveAliveIOCancellation()
        let completion = DriveAliveIOCompletion<Value>()
        let timer = Task.detached(priority: .utility) { [self] in
            do {
                try await Task.sleep(until: deadline, clock: .continuous)
                if state.cancel() { release(key, id: id) }
                completion.resolve(.failure(DriveAliveFailure.timedOut))
            } catch { }
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion.install(continuation)
                let work: @Sendable () -> Void = { [self] in
                    guard state.start() else { return }
                    let result = Result { try operation(state) }
                    release(key, id: id)
                    completion.resolve(result)
                }
                if let schedule { schedule(work) } else { queue.async(execute: work) }
            }
        } onCancel: {
            if state.cancel() { self.release(key, id: id) }
            completion.resolve(.failure(CancellationError()))
        }
    }

    private func claim(_ key: String, id: UUID) -> Bool {
        lock.withLock {
            guard active[key] == nil else { return false }
            active[key] = id
            return true
        }
    }

    private func release(_ key: String, id: UUID) {
        lock.withLock {
            if active[key] == id { active.removeValue(forKey: key) }
        }
    }
}

final class DriveAliveIOCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var cancelled = false

    func start() -> Bool {
        lock.withLock {
            guard !cancelled else { return false }
            started = true
            return true
        }
    }

    /// True means queued work can release its reservation immediately.
    func cancel() -> Bool {
        lock.withLock {
            cancelled = true
            return !started
        }
    }

    func check() throws {
        if lock.withLock({ cancelled }) { throw CancellationError() }
    }
}

private final class DriveAliveIOCompletion<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var pending: Result<Value, Error>?
    private var resolved = false

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let pending {
            self.pending = nil
            lock.unlock()
            continuation.resume(with: pending)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func resolve(_ result: Result<Value, Error>) {
        lock.lock()
        guard !resolved else { lock.unlock(); return }
        resolved = true
        guard let continuation else {
            pending = result
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }
}

import Darwin
import Foundation

struct BoundedProcessResult: Sendable {
    let output: Data
    let terminationStatus: Int32
    let timedOut: Bool
    let outputExceededLimit: Bool
}

/// Runs a fixed executable without a shell while continuously draining its
/// output. The process is terminated on cancellation, timeout, or output-limit
/// breach so a full pipe or stale authorization dialog cannot hang OpenFind's
/// power-state recovery path indefinitely.
enum BoundedProcessRunner {
    static func run(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval,
        outputLimit: Int,
        input: Data? = nil,
        discardStandardError: Bool = false
    ) async throws -> BoundedProcessResult {
        guard executableURL.isFileURL,
              timeout.isFinite,
              timeout > 0,
              outputLimit > 0 else {
            throw BoundedProcessError.invalidConfiguration
        }

        let worker = Task.detached(priority: .utility) {
            try runSynchronously(
                executableURL: executableURL,
                arguments: arguments,
                timeout: timeout,
                outputLimit: outputLimit,
                input: input,
                discardStandardError: discardStandardError
            )
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func runSynchronously(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval,
        outputLimit: Int,
        input: Data?,
        discardStandardError: Bool
    ) throws -> BoundedProcessResult {
        try Task.checkCancellation()
        let process = Process()
        let pipe = Pipe()
        let inputPipe = input == nil ? nil : Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        if let inputPipe { process.standardInput = inputPipe }
        else { process.standardInput = FileHandle.nullDevice }
        process.standardOutput = pipe
        if discardStandardError { process.standardError = FileHandle.nullDevice }
        else { process.standardError = pipe }

        defer {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
            try? inputPipe?.fileHandleForReading.close()
            try? inputPipe?.fileHandleForWriting.close()
        }

        do {
            try process.run()
        } catch {
            throw BoundedProcessError.launchFailed
        }
        defer {
            stop(process)
            process.waitUntilExit()
        }
        try? pipe.fileHandleForWriting.close()
        try? inputPipe?.fileHandleForReading.close()

        let descriptor = pipe.fileHandleForReading.fileDescriptor
        let oldFlags = fcntl(descriptor, F_GETFL)
        guard oldFlags >= 0, fcntl(descriptor, F_SETFL, oldFlags | O_NONBLOCK) == 0 else {
            throw BoundedProcessError.outputReadFailed
        }
        var inputOffset = 0
        var inputClosed = false
        if let inputPipe {
            let descriptor = inputPipe.fileHandleForWriting.fileDescriptor
            let flags = fcntl(descriptor, F_GETFL)
            // A helper may exit before consuming stdin. Suppress SIGPIPE only
            // on this descriptor, never process-wide for the GUI application.
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0,
                  fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0 else {
                throw BoundedProcessError.inputWriteFailed
            }
        }

        var output = Data()
        output.reserveCapacity(min(outputLimit, 64 * 1_024))
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        let deadline = ContinuousClock.now + .seconds(timeout)
        var timedOut = false
        var outputExceededLimit = false
        var readFailed = false

        while true {
            if let inputPipe, let input, inputOffset < input.count {
                let written = input.withUnsafeBytes { bytes in
                    Darwin.write(inputPipe.fileHandleForWriting.fileDescriptor,
                                 bytes.baseAddress!.advanced(by: inputOffset), input.count - inputOffset)
                }
                if written > 0 { inputOffset += written }
                else if written < 0, errno != EAGAIN, errno != EWOULDBLOCK, errno != EINTR {
                    stop(process)
                    throw BoundedProcessError.inputWriteFailed
                }
            }
            if let inputPipe, !inputClosed, inputOffset == input?.count {
                try? inputPipe.fileHandleForWriting.close()
                inputClosed = true
            }
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                let remaining = outputLimit - output.count
                if count > remaining {
                    if remaining > 0 { output.append(contentsOf: buffer.prefix(remaining)) }
                    outputExceededLimit = true
                    stop(process)
                } else {
                    output.append(contentsOf: buffer.prefix(count))
                }
            } else if count <= 0, !process.isRunning {
                break
            } else if count < 0, errno != EAGAIN, errno != EWOULDBLOCK, errno != EINTR {
                readFailed = true
                stop(process)
            }

            if Task.isCancelled {
                stop(process)
                try? pipe.fileHandleForReading.close()
                throw CancellationError()
            }
            if ContinuousClock.now >= deadline, process.isRunning {
                timedOut = true
                stop(process)
            }
            if (timedOut || outputExceededLimit || readFailed), !process.isRunning {
                break
            }
            if count <= 0 { usleep(10_000) }
        }

        if process.isRunning { stop(process) }
        process.waitUntilExit()
        try Task.checkCancellation()
        try? pipe.fileHandleForReading.close()
        if readFailed { throw BoundedProcessError.outputReadFailed }
        return BoundedProcessResult(
            output: output,
            terminationStatus: process.terminationStatus,
            timedOut: timedOut,
            outputExceededLimit: outputExceededLimit
        )
    }

    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = ContinuousClock.now + .milliseconds(200)
        while process.isRunning, ContinuousClock.now < deadline { usleep(10_000) }
        if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
    }
}

enum BoundedProcessError: Error, Equatable {
    case invalidConfiguration
    case launchFailed
    case outputReadFailed
    case inputWriteFailed
}

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
        outputLimit: Int
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
                outputLimit: outputLimit
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
        outputLimit: Int
    ) throws -> BoundedProcessResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            throw BoundedProcessError.launchFailed
        }
        try? pipe.fileHandleForWriting.close()

        let descriptor = pipe.fileHandleForReading.fileDescriptor
        let oldFlags = fcntl(descriptor, F_GETFL)
        if oldFlags >= 0 { _ = fcntl(descriptor, F_SETFL, oldFlags | O_NONBLOCK) }

        var output = Data()
        output.reserveCapacity(min(outputLimit, 64 * 1_024))
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        var outputExceededLimit = false
        var readFailed = false

        while true {
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
            } else if count == 0, !process.isRunning {
                break
            } else if count < 0, errno != EAGAIN, errno != EWOULDBLOCK {
                readFailed = true
                stop(process)
            }

            if Task.isCancelled {
                stop(process)
                try? pipe.fileHandleForReading.close()
                throw CancellationError()
            }
            if Date() >= deadline, process.isRunning {
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
        let deadline = Date().addingTimeInterval(0.2)
        while process.isRunning, Date() < deadline { usleep(10_000) }
        if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
    }
}

enum BoundedProcessError: Error, Equatable {
    case invalidConfiguration
    case launchFailed
    case outputReadFailed
}

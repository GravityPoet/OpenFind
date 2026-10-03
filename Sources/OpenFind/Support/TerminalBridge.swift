import AppKit
import Darwin
import Foundation
import OSLog

/// A single request per process keeps AppleScript execution isolated and makes
/// cancellation terminate the work itself, rather than just its Swift caller.
enum TerminalBridge {
    static let argument = "--terminal-bridge"
    static let maximumRequestBytes = 32 * 1_024
    static let maximumResponseBytes = 2 * 1_024

    struct Request: Codable, Sendable {
        var version = 1
        let target: String
        let command: String
    }

    enum Status: String, Codable, Sendable {
        case delivered, invalidCommand, automationDenied, appleScriptDisabled
        case timedOut, launchFailed, sendFailed
    }

    struct Response: Codable, Sendable {
        let status: Status
        var errorNumber: Int? = nil
    }

    static func send(
        _ command: TerminalCommand,
        target: TerminalCommandTarget,
        timeout: Duration,
        executableURL: URL? = Bundle.main.executableURL
    ) async throws {
        guard let executableURL else { throw TerminalCommandError.launchFailed }
        guard timeout > .zero else { throw TerminalCommandError.timedOut }
        let input = try JSONEncoder().encode(Request(target: target.rawValue, command: command.text))
        let components = timeout.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        let result: BoundedProcessResult
        do {
            result = try await BoundedProcessRunner.run(
                executableURL: executableURL,
                arguments: [argument],
                timeout: seconds,
                outputLimit: maximumResponseBytes,
                input: input,
                discardStandardError: true
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch BoundedProcessError.launchFailed {
            throw TerminalCommandError.launchFailed
        } catch {
            throw TerminalCommandError.sendFailed("")
        }
        if result.timedOut {
            Logger(subsystem: "com.openfind.app", category: "Terminal")
                .error("Terminal bridge timed out: target=\(target.rawValue, privacy: .public)")
            throw TerminalCommandError.timedOut
        }
        guard result.terminationStatus == 0, !result.outputExceededLimit,
              let response = try? JSONDecoder().decode(Response.self, from: result.output) else {
            throw TerminalCommandError.sendFailed("")
        }
        if let number = response.errorNumber {
            Logger(subsystem: "com.openfind.app", category: "Terminal")
                .error("Terminal bridge failed: target=\(target.rawValue, privacy: .public) code=\(number)")
        }
        switch response.status {
        case .delivered: return
        case .invalidCommand: throw TerminalCommandError.invalidCommand
        case .automationDenied: throw TerminalCommandError.automationDenied
        case .appleScriptDisabled: throw TerminalCommandError.appleScriptDisabled
        case .timedOut: throw TerminalCommandError.timedOut
        case .launchFailed: throw TerminalCommandError.launchFailed
        case .sendFailed: throw TerminalCommandError.sendFailed("")
        }
    }

    /// Called synchronously at the executable entry point, before app startup.
    /// Only fixed terminal targets and validated commands cross the boundary;
    /// arbitrary AppleScript and raw error messages never enter the protocol.
    static func handle(
        _ input: Data,
        trustedParent: Bool = true,
        execute: (String) throws -> Void = TerminalCommandRunner.defaultRunScript
    ) -> Response {
        guard input.count <= maximumRequestBytes,
              let request = try? JSONDecoder().decode(Request.self, from: input),
              request.version == 1,
              let target = TerminalCommandTarget(rawValue: request.target),
              TerminalCommandTarget.directTargets.contains(target),
              let command = TerminalCommand(input: request.command) else {
            return Response(status: .invalidCommand)
        }
        guard trustedParent else { return Response(status: .sendFailed) }
        do {
            try execute(TerminalCommandRunner(target: target).source(for: command))
            return Response(status: .delivered)
        } catch let error as TerminalAppleScriptError {
            let status: Status
            switch TerminalCommandRunner.classify(error) {
            case .automationDenied: status = .automationDenied
            case .appleScriptDisabled: status = .appleScriptDisabled
            case .timedOut: status = .timedOut
            case .launchFailed: status = .launchFailed
            default: status = .sendFailed
            }
            return Response(status: status, errorNumber: error.number)
        } catch {
            return Response(status: .sendFailed)
        }
    }

    static func runHelper() -> Int32 {
        // macOS does not automatically kill a Process child when its parent
        // dies. Do not leave an orphan waiting on Apple Events after app exit.
        let parent = getppid()
        guard parent > 1 else { return 74 }
        let trustedParent = sharesExecutable(with: parent)
        let parentMonitor = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        parentMonitor.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(500))
        parentMonitor.setEventHandler {
            if getppid() != parent { _exit(0) }
        }
        parentMonitor.resume()
        defer { parentMonitor.cancel() }

        do {
            var input = Data()
            while let chunk = try FileHandle.standardInput.read(upToCount: 4_096), !chunk.isEmpty {
                input.append(chunk)
                if input.count > maximumRequestBytes { break }
            }
            let response = handle(input, trustedParent: trustedParent)
            try FileHandle.standardOutput.write(contentsOf: JSONEncoder().encode(response))
            return 0
        } catch {
            return 74
        }
    }

    /// Use the kernel's executable path, not argv or a caller-supplied PID.
    /// A shell launching this hidden mode must not borrow the app's consent.
    static func sharesExecutable(with processID: pid_t) -> Bool {
        guard processID > 1 else { return false }
        func executablePath(_ pid: pid_t) -> String? {
            // libproc.h defines PROC_PIDPATHINFO_MAXSIZE as 4 * MAXPATHLEN;
            // Swift cannot import that structured C macro on every SDK.
            var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
            return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        guard let ownPath = executablePath(getpid()),
              let parentPath = executablePath(processID) else { return false }
        return ownPath == parentPath
    }
}

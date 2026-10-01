import AppKit
import Foundation
import OSLog

/// A validated single-line shell command typed after the configured prefix.
struct TerminalCommand: Hashable, Sendable {
    static let maxUTF8Count = 4096
    let text: String

    init?(input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.utf8.count <= Self.maxUTF8Count else { return nil }
        for scalar in input.unicodeScalars {
            switch scalar.value {
            case 0x00...0x08, 0x0A...0x1F, 0x7F...0x9F, 0x2028, 0x2029:
                return nil
            default:
                break
            }
        }
        text = trimmed
    }
}

struct TerminalAppleScriptError: Error {
    let number: Int
    let message: String
}

enum TerminalCommandError: Error, Equatable {
    case invalidCommand
    case terminalUnavailable
    case automationDenied
    case appleScriptDisabled
    case timedOut
    case launchFailed
    case unsupportedTerminal(String)
    case sendFailed(String)
    case updateRequired(String, String)
    case scriptingUnavailable(String)
    case testNotConfirmed
    case deliveryInProgress
}

extension TerminalCommandError {
    var userMessage: String {
        switch self {
        case .invalidCommand: return L("Terminal Invalid Command")
        case .terminalUnavailable: return L("Terminal Unavailable")
        case .automationDenied: return L("Terminal Automation Denied")
        case .appleScriptDisabled: return L("Terminal Script Disabled")
        case .timedOut: return L("Terminal Timed Out")
        case .launchFailed: return L("Terminal Launch Failed")
        case .unsupportedTerminal: return L("Terminal Unsupported")
        case .sendFailed: return L("Terminal Send Failed")
        case .updateRequired(let app, let version):
            return String(format: L("Terminal Update Required"), app, version)
        case .scriptingUnavailable(let app):
            return String(format: L("Terminal Scripting Unavailable"), app)
        case .testNotConfirmed: return L("Terminal Test Not Confirmed")
        case .deliveryInProgress: return L("Terminal Delivery In Progress")
        }
    }

    var recoveryURL: URL? {
        switch self {
        case .automationDenied:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
        case .appleScriptDisabled:
            return URL(string: "https://ghostty.org/docs/features/applescript#security")
        case .updateRequired(let app, _), .scriptingUnavailable(let app):
            if app == "Ghostty" { return URL(string: "https://ghostty.org/download") }
            if app == "iTerm2" { return URL(string: "https://iterm2.com/downloads.html") }
            return nil
        default: return nil
        }
    }
}

/// Sends an explicitly confirmed command to a selected macOS terminal.
/// System Default uses an ephemeral `.command` file, so the user's configured
/// default terminal decides the destination without requiring an app-specific
/// AppleScript permission. Direct targets use their native scripting interfaces.
struct TerminalCommandRunner: Sendable {
    static let appleEventsDeniedNumber = -1743
    static let appleEventsConsentNumber = -1744
    static let eventTimeoutSeconds = 15
    private static let queue = DispatchQueue(
        label: "com.openfind.terminal",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private static let deliveryLanes = TerminalDeliveryLanes()

    let target: TerminalCommandTarget
    var findApplication: @Sendable (String) -> URL?
    var runScript: @Sendable (String) throws -> Void
    var openDefaultCommand: @Sendable (TerminalCommand) throws -> Void
    var validateApplication: @Sendable (TerminalCommandTarget, URL) throws -> Void

    init(
        target: TerminalCommandTarget = .defaultValue,
        findApplication: @Sendable @escaping (String) -> URL? = { id in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        },
        runScript: @Sendable @escaping (String) throws -> Void = TerminalCommandRunner.defaultRunScript,
        openDefaultCommand: @Sendable @escaping (TerminalCommand) throws -> Void = TerminalCommandRunner.defaultOpenCommand,
        validateApplication: @Sendable @escaping (TerminalCommandTarget, URL) throws -> Void = { target, url in
            if let error = TerminalInstallation(target: target, url: url).error { throw error }
        }
    ) {
        self.target = target
        self.findApplication = findApplication
        self.runScript = runScript
        self.openDefaultCommand = openDefaultCommand
        self.validateApplication = validateApplication
    }

    static func defaultRunScript(_ source: String) throws {
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw TerminalAppleScriptError(number: -1, message: "AppleScript compile failed")
        }
        script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let rawNumber = errorInfo["NSAppleScriptErrorNumber"]
            let number = (rawNumber as? Int) ?? (rawNumber as? NSNumber)?.intValue ?? -1
            let message = (errorInfo["NSAppleScriptErrorMessage"] as? String)
                ?? "AppleScript execution failed"
            throw TerminalAppleScriptError(number: number, message: message)
        }
    }

    static func defaultScript(for command: TerminalCommand) -> String {
        "#!/bin/zsh -i\n" + command.text + "\n"
    }

    static func defaultOpenCommand(_ command: TerminalCommand) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenFind-TerminalCommands", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("command")
        let script = defaultScript(for: command)
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        guard NSWorkspace.shared.open(url) else { throw TerminalCommandError.terminalUnavailable }
        // The terminal has received the URL; keep it briefly for slow launchers,
        // then remove only this file; other deliveries may still be using the directory.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 120) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func source(for command: TerminalCommand) -> String {
        switch target {
        case .terminal:
            return """
            with timeout of \(Self.eventTimeoutSeconds) seconds
            tell application id "com.apple.Terminal"
                activate
                do script "\(Self.escapedForAppleScript(command.text))"
            end tell
            end timeout
            """
        case .ghostty:
            return """
            with timeout of \(Self.eventTimeoutSeconds) seconds
            tell application id "com.mitchellh.ghostty"
                activate
                if (count of windows) > 0 then
                    set targetWindow to front window
                    set targetTab to new tab in targetWindow
                else
                    set targetWindow to new window
                    set targetTab to selected tab of targetWindow
                end if
                set targetTerminal to focused terminal of targetTab
                input text "\(Self.escapedForAppleScript(command.text))" to targetTerminal
                send key "enter" to targetTerminal
            end tell
            end timeout
            """
        case .iterm2:
            return """
            with timeout of \(Self.eventTimeoutSeconds) seconds
            tell application id "com.googlecode.iterm2"
                activate
                if (count of windows) > 0 then
                    set targetWindow to current window
                    tell targetWindow
                        set targetTab to create tab with default profile
                    end tell
                else
                    set targetWindow to create window with default profile
                    set targetTab to current tab of targetWindow
                end if
                tell current session of targetTab
                    write text "\(Self.escapedForAppleScript(command.text))"
                end tell
            end tell
            end timeout
            """
        case .systemDefault:
            return ""
        }
    }

    static func escapedForAppleScript(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func classify(_ error: TerminalAppleScriptError) -> TerminalCommandError {
        if error.message.contains("AppleScript is disabled by the macos-applescript configuration.") {
            return .appleScriptDisabled
        }
        if [appleEventsDeniedNumber, appleEventsConsentNumber].contains(error.number) {
            return .automationDenied
        }
        if error.number == -1712 { return .timedOut }
        if [-600, -609].contains(error.number) { return .launchFailed }
        return .sendFailed(error.message)
    }

    func send(
        _ command: TerminalCommand,
        timeout: Duration = .seconds(TerminalCommandRunner.eventTimeoutSeconds)
    ) async throws {
        try Task.checkCancellation()
        let laneKey = target.rawValue
        if target == .systemDefault {
            guard Self.deliveryLanes.acquire(laneKey) else {
                throw TerminalCommandError.deliveryInProgress
            }
            let open = openDefaultCommand
            try await Self.runOffMain(timeout: timeout, laneKey: laneKey) { try open(command) }
            return
        }
        guard let bundleIdentifier = target.bundleIdentifier,
              let applicationURL = findApplication(bundleIdentifier) else {
            throw TerminalCommandError.terminalUnavailable
        }
        try validateApplication(target, applicationURL)
        guard Self.deliveryLanes.acquire(laneKey) else {
            throw TerminalCommandError.deliveryInProgress
        }
        let source = source(for: command)
        let execute = runScript
        do {
            try await Self.runOffMain(timeout: timeout, laneKey: laneKey) { try execute(source) }
        } catch let error as TerminalAppleScriptError {
            // Raw error messages can contain user commands; log only target and code.
            Logger(subsystem: "com.openfind.app", category: "Terminal")
                .error("Terminal delivery failed: target=\(target.rawValue, privacy: .public) code=\(error.number)")
            throw Self.classify(error)
        }
    }

    /// A successful Apple event proves delivery, not shell execution. The
    /// explicit settings test confirms execution with a unique local receipt.
    func testConnection(timeout: Duration = .seconds(10)) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenFind-TerminalTest-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let receipt = directory.appendingPathComponent("receipt")
        let nonce = UUID().uuidString
        let quotedPath = "'" + receipt.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let command = TerminalCommand(input: "printf 'OpenFind terminal test OK\\n'; printf '%s' '\(nonce)' > \(quotedPath)")!
        try await send(command)
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if (try? String(contentsOf: receipt, encoding: .utf8)) == nonce { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw TerminalCommandError.testNotConfirmed
    }

    private static func runOffMain(
        timeout: Duration,
        laneKey: String,
        operation: @escaping @Sendable () throws -> Void
    ) async throws {
        let completion = TerminalDeliveryCompletion()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion.install(continuation)
                queue.async {
                    guard completion.begin() else {
                        deliveryLanes.release(laneKey)
                        return
                    }
                    defer { deliveryLanes.release(laneKey) }
                    do { try operation(); completion.finish(.success(())) }
                    catch { completion.finish(.failure(error)) }
                }
                let timeoutTask = Task.detached {
                    do { try await Task.sleep(for: timeout) }
                    catch { return }
                    completion.finish(.failure(TerminalCommandError.timedOut))
                }
                completion.setTimeoutTask(timeoutTask)
            }
        } onCancel: {
            completion.finish(.failure(CancellationError()))
        }
    }
}

/// Keeps one request per terminal target in flight. A timed-out AppleScript
/// may still be unwinding below the timeout boundary; rejecting a second
/// request prevents duplicate commands while the underlying call finishes.
private final class TerminalDeliveryLanes: @unchecked Sendable {
    private let lock = NSLock()
    private var active: Set<String> = []

    func acquire(_ key: String) -> Bool {
        lock.withLock {
            guard !active.contains(key) else { return false }
            active.insert(key)
            return true
        }
    }

    func release(_ key: String) {
        _ = lock.withLock { active.remove(key) }
    }
}

/// Resumes a delivery continuation exactly once, even when an Apple event
/// finishes after the watchdog has already released the UI.
private final class TerminalDeliveryCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var result: Result<Void, Error>?

    func install(_ continuation: CheckedContinuation<Void, Error>) {
        let existingResult: Result<Void, Error>? = lock.withLock {
            if let currentResult = self.result { return currentResult }
            self.continuation = continuation
            return nil
        }
        if let existingResult { continuation.resume(with: existingResult) }
    }

    func setTimeoutTask(_ task: Task<Void, Never>) {
        let finished = lock.withLock {
            guard result == nil else { return true }
            timeoutTask = task
            return false
        }
        if finished { task.cancel() }
    }

    func begin() -> Bool {
        lock.withLock { result == nil }
    }

    func finish(_ result: Result<Void, Error>) {
        let pending = lock.withLock { () -> (CheckedContinuation<Void, Error>?, Task<Void, Never>?)? in
            guard self.result == nil else { return nil }
            self.result = result
            let pending = (continuation, timeoutTask)
            continuation = nil
            timeoutTask = nil
            return pending
        }
        guard let pending else { return }
        pending.1?.cancel()
        pending.0?.resume(with: result)
    }
}

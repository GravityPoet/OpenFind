import AppKit
import Foundation

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
        }
    }
}

/// Sends an explicitly confirmed command to a selected macOS terminal.
/// System Default uses an ephemeral `.command` file, so the user's configured
/// default terminal decides the destination without requiring an app-specific
/// AppleScript permission. Explicit Terminal/Ghostty targets use AppleScript.
struct TerminalCommandRunner: Sendable {
    static let appleEventsDeniedNumber = -1743
    static let eventTimeoutSeconds = 15
    private static let queue = DispatchQueue(label: "com.openfind.terminal", qos: .userInitiated)

    let target: TerminalCommandTarget
    var findApplication: @Sendable (String) -> URL?
    var runScript: @Sendable (String) throws -> Void
    var openDefaultCommand: @Sendable (TerminalCommand) throws -> Void

    init(
        target: TerminalCommandTarget = .systemDefault,
        findApplication: @Sendable @escaping (String) -> URL? = { id in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        },
        runScript: @Sendable @escaping (String) throws -> Void = TerminalCommandRunner.defaultRunScript,
        openDefaultCommand: @Sendable @escaping (TerminalCommand) throws -> Void = TerminalCommandRunner.defaultOpenCommand
    ) {
        self.target = target
        self.findApplication = findApplication
        self.runScript = runScript
        self.openDefaultCommand = openDefaultCommand
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

    static func defaultOpenCommand(_ command: TerminalCommand) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenFind-TerminalCommands", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("command")
        let script = "#!/bin/zsh\n" + command.text + "\n"
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        guard NSWorkspace.shared.open(url) else { throw TerminalCommandError.terminalUnavailable }
        // The terminal has received the URL; keep it briefly for slow launchers,
        // then remove the command file and its directory.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 120) {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: directory)
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
        if error.number == appleEventsDeniedNumber { return .automationDenied }
        if error.number == -1712 { return .timedOut }
        if [-600, -609].contains(error.number) { return .launchFailed }
        return .sendFailed(error.message)
    }

    func send(_ command: TerminalCommand) async throws {
        try Task.checkCancellation()
        if target == .systemDefault {
            let open = openDefaultCommand
            try await Self.runOffMain { try open(command) }
            return
        }
        guard let bundleIdentifier = target.bundleIdentifier,
              findApplication(bundleIdentifier) != nil else {
            throw TerminalCommandError.terminalUnavailable
        }
        let source = source(for: command)
        let execute = runScript
        do {
            try await Self.runOffMain { try execute(source) }
        } catch let error as TerminalAppleScriptError {
            throw Self.classify(error)
        }
    }

    private static func runOffMain(_ operation: @escaping @Sendable () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { try operation(); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}

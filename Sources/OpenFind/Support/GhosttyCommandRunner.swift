import AppKit
import Foundation

/// A validated single-line shell command typed after the configured prefix.
/// Validation keeps user text as paste-like data: surrounding whitespace is
/// trimmed, empty input is rejected, and anything that could change single-line
/// semantics (NUL, CR/LF, other C0 controls except tab, DEL, Unicode line
/// separators) or exceed the UTF-8 budget is rejected.
struct GhosttyCommand: Hashable, Sendable {
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
        self.text = trimmed
    }
}

/// Raw AppleScript execution failure, carrying the script error number so the
/// runner can tell Automation denial apart from other failures.
struct GhosttyAppleScriptError: Error {
    let number: Int
    let message: String
}

enum GhosttyCommandError: Error, Equatable {
    case invalidCommand
    case ghosttyNotInstalled
    case automationDenied
    case appleScriptDisabled
    case timedOut
    case launchFailed
    case sendFailed(String)
}

extension GhosttyCommandError {
    var userMessage: String {
        switch self {
        case .invalidCommand:
            L("Ghostty Invalid Command")
        case .ghosttyNotInstalled:
            L("Ghostty Not Installed")
        case .automationDenied:
            L("Ghostty Automation Denied")
        case .appleScriptDisabled:
            L("Ghostty AppleScript Disabled")
        case .timedOut:
            L("Ghostty Timed Out")
        case .launchFailed:
            L("Ghostty Launch Failed")
        case .sendFailed:
            L("Ghostty Send Failed")
        }
    }
}

/// Thin adapter that delivers a validated command to a new Ghostty tab.
///
/// The AppleScript source is fixed; user text is only ever embedded as an
/// escaped string literal for `input text`, never as script structure.
/// OpenFind never executes the command itself: no `do shell script`,
/// no `/bin/sh -c`, no Process.
///
/// MVP always targets a new tab (or a new window when Ghostty has none),
/// never the currently focused terminal, so running Vim/SSH/tmux sessions
/// are left untouched.
struct GhosttyCommandRunner: Sendable {
    static let ghosttyBundleIdentifier = "com.mitchellh.ghostty"
    /// macOS TCC denial for AppleEvents.
    static let automationDeniedNumber = -1743
    static let eventTimeoutSeconds = 15
    private static let scriptQueue = DispatchQueue(label: "com.openfind.ghostty", qos: .userInitiated)

    var findApplication: @Sendable () -> URL?
    var runScript: @Sendable (String) throws -> Void

    init(
        findApplication: @Sendable @escaping () -> URL? = GhosttyCommandRunner.defaultFindApplication,
        runScript: @Sendable @escaping (String) throws -> Void = GhosttyCommandRunner.defaultRunScript
    ) {
        self.findApplication = findApplication
        self.runScript = runScript
    }

    static func defaultFindApplication() -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: ghosttyBundleIdentifier)
    }

    static func defaultRunScript(_ source: String) throws {
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw GhosttyAppleScriptError(number: -1, message: "AppleScript compile failed")
        }
        script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let rawNumber = errorInfo["NSAppleScriptErrorNumber"]
            let number = (rawNumber as? Int) ?? (rawNumber as? NSNumber)?.intValue ?? -1
            let message = (errorInfo["NSAppleScriptErrorMessage"] as? String)
                ?? "AppleScript execution failed"
            throw GhosttyAppleScriptError(number: number, message: message)
        }
    }

    /// Builds the single fixed AppleScript for the command. Must stay callable
    /// exactly once per `send`: window branching happens inside the script.
    func source(for command: GhosttyCommand) -> String {
        """
        with timeout of \(Self.eventTimeoutSeconds) seconds
        tell application id "\(Self.ghosttyBundleIdentifier)"
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
    }

    static func escapedForAppleScript(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func classify(_ error: GhosttyAppleScriptError) -> GhosttyCommandError {
        // Ghostty 1.3 emits this explicit message only when its config disables scripting.
        if error.message.contains("AppleScript is disabled by the macos-applescript configuration.") {
            return .appleScriptDisabled
        }
        if error.number == automationDeniedNumber {
            return .automationDenied
        }
        if error.number == -1712 { return .timedOut }
        if [-600, -609].contains(error.number) { return .launchFailed }
        return .sendFailed(error.message)
    }

    /// NSAppleScript work is serialized off the main thread. Do not retry failed
    /// events automatically: a timeout cannot prove whether Ghostty consumed input.
    func send(_ command: GhosttyCommand) async throws {
        try Task.checkCancellation()
        guard findApplication() != nil else {
            throw GhosttyCommandError.ghosttyNotInstalled
        }
        let source = source(for: command)
        let execute = runScript
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Self.scriptQueue.async {
                do {
                    try execute(source)
                    continuation.resume()
                } catch let error as GhosttyAppleScriptError {
                    continuation.resume(throwing: Self.classify(error))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

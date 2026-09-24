import Foundation
import Testing
@testable import OpenFind

@Suite("Ghostty Command Tests")
struct GhosttyCommandRunnerTests {
    @Test func ghosttyModeRequiresExplicitGSpace() {
        #expect(QuickSearchCommand.parse("g git status") == .init(mode: .terminal, term: "git status"))
        #expect(QuickSearchCommand.parse("G ls -la") == .init(mode: .terminal, term: "ls -la"))
        #expect(QuickSearchCommand.parse("g") == .init(mode: .combined, term: "g"))
        let barePrefix = QuickSearchCommand.parse("g ")
        #expect(barePrefix.mode == .terminal)
        #expect(barePrefix.term.isEmpty)
        #expect(QuickSearchCommand.parse("git status").mode == .combined)
        #expect(QuickSearchCommand.parse("terminal ls").mode == .combined)
        #expect(QuickSearchCommand.parse("ghostty ls").mode == .combined)
        #expect(QuickSearchCommand.parse("g\tls").mode == .combined)
        #expect(QuickSearchMode.bookmarks.prefix == "bm ")
        #expect(QuickSearchCommand.parse("g printf ok\n").term == "printf ok\n")
        #expect(QuickSearchCommand.parse("g echo \"hi\" && ls | grep x").term == "echo \"hi\" && ls | grep x")
    }

    @Test func ghosttyCommandValidationKeepsSingleLineShellText() {
        #expect(GhosttyCommand(input: "git status")?.text == "git status")
        #expect(GhosttyCommand(input: "  git status  ")?.text == "git status")
        #expect(GhosttyCommand(input: "echo \"a\\b\" && ls | grep x")?.text == "echo \"a\\b\" && ls | grep x")
        #expect(GhosttyCommand(input: "printf 'a\tb'")?.text == "printf 'a\tb'")
        #expect(GhosttyCommand(input: "") == nil)
        #expect(GhosttyCommand(input: "   ") == nil)
        #expect(GhosttyCommand(input: "a\nb") == nil)
        #expect(GhosttyCommand(input: "a\rb") == nil)
        #expect(GhosttyCommand(input: "\nprintf ok") == nil)
        #expect(GhosttyCommand(input: "printf ok\r\n") == nil)
        #expect(GhosttyCommand(input: "\u{2028}printf ok") == nil)
        #expect(GhosttyCommand(input: "a\0b") == nil)
        #expect(GhosttyCommand(input: "a\u{2028}b") == nil)
        #expect(GhosttyCommand(input: "a\u{7F}b") == nil)
        #expect(GhosttyCommand(input: String(repeating: "x", count: 5000)) == nil)
        #expect(GhosttyCommand(input: String(repeating: "x", count: 4096))?.text.count == 4096)
    }

    @Test func ghosttyScriptUsesOneFixedTemplateWithBothWindowBranches() {
        let command = GhosttyCommand(input: "git status")!
        let runner = GhosttyCommandRunner(
            findApplication: { URL(fileURLWithPath: "/Applications/Ghostty.app") },
            runScript: { _ in }
        )
        let source = runner.source(for: command)
        #expect(source.contains("tell application id \"com.mitchellh.ghostty\""))
        #expect(source.contains("with timeout of 15 seconds"))
        #expect(source.contains("new tab in targetWindow"))
        #expect(source.contains("set targetWindow to new window"))
        #expect(source.contains("focused terminal of targetTab"))
        #expect(source.contains("input text \"git status\" to targetTerminal"))
        #expect(source.contains("send key \"enter\" to targetTerminal"))
        #expect(!source.contains("do shell script"))
        #expect(!source.contains("/bin/sh"))
    }

    @Test func ghosttyScriptEscapesQuotesAndBackslashesWithoutChangingStructure() {
        let command = GhosttyCommand(input: "echo \"a\\b\" && ls")!
        let runner = GhosttyCommandRunner(
            findApplication: { URL(fileURLWithPath: "/Applications/Ghostty.app") },
            runScript: { _ in }
        )
        let source = runner.source(for: command)
        #expect(source.contains("input text \"echo \\\"a\\\\b\\\" && ls\" to targetTerminal"))
    }

    @MainActor
    @Test func ghosttyTerminalResultsOnlyForNonEmptyCommand() async throws {
        let model = QuickSearchViewModel(
            searchApplications: { _ in [] },
            searchSettings: { _ in [] },
            searchFiles: { _ in QuickSearchFileResponse() }
        )
        defer { model.cancel() }
        model.query = "g git status"
        for _ in 0..<100 where model.isSearching || model.results.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.commandMode == .terminal)
        #expect(model.results.count == 1)
        #expect(model.results.first?.action == .ghostty("git status"))
        #expect(model.results.first?.kind == .command)
        model.query = "g "
        for _ in 0..<100 where model.isSearching {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.commandMode == .terminal)
        #expect(model.results.isEmpty)
    }

    @MainActor
    @Test func ghosttySendCallsExecutorOnce() async throws {
        let log = GhosttyScriptCallLog()
        let runner = GhosttyCommandRunner(
            findApplication: { URL(fileURLWithPath: "/Applications/Ghostty.app") },
            runScript: { source in log.record(source) }
        )
        try await runner.send(GhosttyCommand(input: "git status")!)
        #expect(log.sources.count == 1)
        #expect(log.sources.first?.contains("git status") == true)
    }

    @MainActor
    @Test func ghosttySendDistinguishesInstallAutomationAndScriptStates() async {
        let missing = GhosttyCommandRunner(
            findApplication: { nil },
            runScript: { _ in }
        )
        await #expect(throws: GhosttyCommandError.ghosttyNotInstalled) {
            try await missing.send(GhosttyCommand(input: "git status")!)
        }

        let denied = GhosttyCommandRunner(
            findApplication: { URL(fileURLWithPath: "/Applications/Ghostty.app") },
            runScript: { _ in throw GhosttyAppleScriptError(number: -1743, message: "Not permitted") }
        )
        await #expect(throws: GhosttyCommandError.automationDenied) {
            try await denied.send(GhosttyCommand(input: "git status")!)
        }

        let probeFailed = GhosttyCommandRunner(
            findApplication: { URL(fileURLWithPath: "/Applications/Ghostty.app") },
            runScript: { _ in throw GhosttyAppleScriptError(
                number: -1743,
                message: "Ghostty got an error: AppleScript is disabled by the macos-applescript configuration."
            ) }
        )
        await #expect(throws: GhosttyCommandError.appleScriptDisabled) {
            try await probeFailed.send(GhosttyCommand(input: "git status")!)
        }

        let sendFailed = GhosttyCommandRunner(
            findApplication: { URL(fileURLWithPath: "/Applications/Ghostty.app") },
            runScript: { _ in throw GhosttyAppleScriptError(number: -1700, message: "Some failure") }
        )
        await #expect(throws: GhosttyCommandError.sendFailed("Some failure")) {
            try await sendFailed.send(GhosttyCommand(input: "git status")!)
        }
        #expect(GhosttyCommandRunner.classify(.init(number: -1712, message: "timeout")) == .timedOut)
        #expect(GhosttyCommandRunner.classify(.init(number: -600, message: "not running")) == .launchFailed)
        #expect(GhosttyCommandRunner.classify(.init(number: -609, message: "invalid connection")) == .launchFailed)
    }
}

private final class GhosttyScriptCallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var sources: [String] {
        lock.withLock { recorded }
    }

    func record(_ source: String) {
        lock.withLock { recorded.append(source) }
    }
}

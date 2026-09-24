import Foundation
import Testing
@testable import OpenFind

@Suite("Terminal Command Tests")
struct TerminalCommandRunnerTests {
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
        #expect(TerminalCommand(input: "git status")?.text == "git status")
        #expect(TerminalCommand(input: "  git status  ")?.text == "git status")
        #expect(TerminalCommand(input: "echo \"a\\b\" && ls | grep x")?.text == "echo \"a\\b\" && ls | grep x")
        #expect(TerminalCommand(input: "printf 'a\tb'")?.text == "printf 'a\tb'")
        #expect(TerminalCommand(input: "") == nil)
        #expect(TerminalCommand(input: "   ") == nil)
        #expect(TerminalCommand(input: "a\nb") == nil)
        #expect(TerminalCommand(input: "a\rb") == nil)
        #expect(TerminalCommand(input: "\nprintf ok") == nil)
        #expect(TerminalCommand(input: "printf ok\r\n") == nil)
        #expect(TerminalCommand(input: "\u{2028}printf ok") == nil)
        #expect(TerminalCommand(input: "a\0b") == nil)
        #expect(TerminalCommand(input: "a\u{2028}b") == nil)
        #expect(TerminalCommand(input: "a\u{7F}b") == nil)
        #expect(TerminalCommand(input: String(repeating: "x", count: 5000)) == nil)
        #expect(TerminalCommand(input: String(repeating: "x", count: 4096))?.text.count == 4096)
    }

    @Test func ghosttyScriptUsesOneFixedTemplateWithBothWindowBranches() {
        let command = TerminalCommand(input: "git status")!
        let runner = TerminalCommandRunner(target: .ghostty,
            findApplication: { _ in URL(fileURLWithPath: "/Applications/Ghostty.app") },
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
        let command = TerminalCommand(input: "echo \"a\\b\" && ls")!
        let runner = TerminalCommandRunner(target: .ghostty,
            findApplication: { _ in URL(fileURLWithPath: "/Applications/Ghostty.app") },
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
        #expect(model.results.first?.action == .terminal("git status"))
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
        let log = TerminalScriptCallLog()
        let runner = TerminalCommandRunner(target: .ghostty,
            findApplication: { _ in URL(fileURLWithPath: "/Applications/Ghostty.app") },
            runScript: { source in log.record(source) }
        )
        try await runner.send(TerminalCommand(input: "git status")!)
        #expect(log.sources.count == 1)
        #expect(log.sources.first?.contains("git status") == true)
    }

    @MainActor
    @Test func ghosttySendDistinguishesInstallAutomationAndScriptStates() async {
        let missing = TerminalCommandRunner(target: .ghostty,
            findApplication: { _ in nil },
            runScript: { _ in }
        )
        await #expect(throws: TerminalCommandError.terminalUnavailable) {
            try await missing.send(TerminalCommand(input: "git status")!)
        }

        let denied = TerminalCommandRunner(target: .ghostty,
            findApplication: { _ in URL(fileURLWithPath: "/Applications/Ghostty.app") },
            runScript: { _ in throw TerminalAppleScriptError(number: -1743, message: "Not permitted") }
        )
        await #expect(throws: TerminalCommandError.automationDenied) {
            try await denied.send(TerminalCommand(input: "git status")!)
        }

        let probeFailed = TerminalCommandRunner(target: .ghostty,
            findApplication: { _ in URL(fileURLWithPath: "/Applications/Ghostty.app") },
            runScript: { _ in throw TerminalAppleScriptError(
                number: -1743,
                message: "Ghostty got an error: AppleScript is disabled by the macos-applescript configuration."
            ) }
        )
        await #expect(throws: TerminalCommandError.appleScriptDisabled) {
            try await probeFailed.send(TerminalCommand(input: "git status")!)
        }

        let sendFailed = TerminalCommandRunner(target: .ghostty,
            findApplication: { _ in URL(fileURLWithPath: "/Applications/Ghostty.app") },
            runScript: { _ in throw TerminalAppleScriptError(number: -1700, message: "Some failure") }
        )
        await #expect(throws: TerminalCommandError.sendFailed("Some failure")) {
            try await sendFailed.send(TerminalCommand(input: "git status")!)
        }
        #expect(TerminalCommandRunner.classify(.init(number: -1712, message: "timeout")) == .timedOut)
        #expect(TerminalCommandRunner.classify(.init(number: -600, message: "not running")) == .launchFailed)
        #expect(TerminalCommandRunner.classify(.init(number: -609, message: "invalid connection")) == .launchFailed)
    }

    @Test func systemDefaultTargetUsesInjectedDefaultHandlerWithoutAppleScript() async throws {
        let command = try #require(TerminalCommand(input: "printf ok"))
        let opened = TerminalCommandLog()
        let runner = TerminalCommandRunner(
            target: .systemDefault,
            runScript: { _ in Issue.record("System default target must not require AppleScript") },
            openDefaultCommand: { opened.record($0.text) }
        )
        try await runner.send(command)
        #expect(opened.value == "printf ok")
    }

    @Test func systemDefaultScriptUsesInteractiveZshAndKeepsCommandSyntax() throws {
        let command = try #require(TerminalCommand(input: "echo \"$HOME\" && pwd"))
        #expect(TerminalCommandRunner.defaultScript(for: command) == "#!/bin/zsh -i\necho \"$HOME\" && pwd\n")
    }
}

private final class TerminalScriptCallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var sources: [String] {
        lock.withLock { recorded }
    }

    func record(_ source: String) {
        lock.withLock { recorded.append(source) }
    }
}

private final class TerminalCommandLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = ""

    var value: String { lock.withLock { stored } }

    func record(_ value: String) {
        lock.withLock { stored = value }
    }
}

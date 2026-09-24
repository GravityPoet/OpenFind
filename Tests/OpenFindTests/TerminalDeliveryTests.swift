import AppKit
import Testing
@testable import OpenFind

@MainActor
@Suite("Terminal Delivery", .serialized)
struct TerminalDeliveryTests {
    @Test(arguments: ["g", "x"])
    func terminalEntryPrefillsPrefixAndFocusesInputWithoutExecuting(prefix: String) async throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: QuickTerminalPrefix.persistenceKey)
        defaults.set(prefix, forKey: QuickTerminalPrefix.persistenceKey)
        defer {
            if let previous { defaults.set(previous, forKey: QuickTerminalPrefix.persistenceKey) }
            else { defaults.removeObject(forKey: QuickTerminalPrefix.persistenceKey) }
        }
        let controller = QuickSearchWindowController(
            onShowFullSearch: { _ in },
            sendTerminalCommand: { _ in Issue.record("Discovery hint must not execute a command") }
        )
        defer { controller.close() }
        controller.show()
        #expect(controller.viewModel.query.isEmpty)
        controller.beginTerminalCommand()
        try await waitUntil { !controller.viewModel.isSearching }
        #expect(controller.viewModel.query == prefix + " ")
        #expect(controller.viewModel.commandMode == .terminal)
        #expect(controller.viewModel.results.isEmpty)
        let editor = try #require(controller.panel?.firstResponder as? NSTextView)
        #expect(editor.isFieldEditor)
        #expect(editor.string == prefix + " ")
        #expect(editor.selectedRange() == NSRange(location: 2, length: 0))
    }

    @Test func concurrentDeliveriesAreSerializedOffMainThread() async throws {
        let probe = TerminalExecutionProbe()
        let runner = TerminalCommandRunner(target: .ghostty,
            findApplication: { _ in URL(fileURLWithPath: "/Applications/Ghostty.app") },
            runScript: { _ in probe.run() }
        )
        let command = try #require(TerminalCommand(input: "printf ok"))
        async let first: Void = runner.send(command)
        async let second: Void = runner.send(command)
        try await first
        try await second
        #expect(probe.snapshot == [2, 1, 0])
    }

    @Test func failureAfterDismissalPreservesCommandAndCanRetry() async throws {
        _ = NSApplication.shared
        let delivery = TerminalTestDelivery()
        let controller = QuickSearchWindowController(
            onShowFullSearch: { _ in Issue.record("Terminal command entered full search") },
            sendTerminalCommand: { try await delivery.send($0) }
        )
        defer { controller.close() }
        controller.show()
        controller.viewModel.query = "g printf ok"
        try await waitUntil { controller.viewModel.selectedResult != nil }
        controller.panel?.onFullSearch?()
        #expect(controller.isVisible)
        controller.open(try #require(controller.viewModel.selectedResult))
        try await waitUntil { controller.viewModel.isSendingCommand }
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
        #expect(controller.isVisible)
        controller.close()
        await delivery.finishWithFailure()
        try await waitUntil { controller.viewModel.errorMessage != nil }
        #expect(controller.isVisible)
        #expect(controller.viewModel.query == "g printf ok")
        #expect(controller.viewModel.selectedResult?.action == .terminal("printf ok"))
        controller.open(try #require(controller.viewModel.selectedResult))
        try await waitUntil { !controller.isVisible }
        #expect(await delivery.calls == 2)
    }

    @Test func invalidCommandShowsAnErrorWithoutProducingAnAction() async throws {
        let model = QuickSearchViewModel()
        defer { model.cancel() }
        model.query = "g printf ok\n"
        try await waitUntil { !model.isSearching }
        #expect(model.results.isEmpty)
        #expect(model.statusMessage == L("Terminal Invalid Command"))
    }

    @Test func appleScriptLiteralRoundTripsShellSyntaxWithoutExecutingIt() throws {
        let text = "printf '%s' \"中文 \\ $HOME $(printf unsafe)\" && echo done | cat"
        let command = try #require(TerminalCommand(input: text))
        let source = "return \"" + TerminalCommandRunner.escapedForAppleScript(command.text) + "\""
        let script = try #require(NSAppleScript(source: source))
        var error: NSDictionary?
        #expect(script.executeAndReturnError(&error).stringValue == text)
        #expect(error == nil)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CocoaError(.coderInvalidValue)
    }
}

private actor TerminalTestDelivery {
    private(set) var calls = 0
    private var pending: CheckedContinuation<Void, Error>?
    func send(_ command: TerminalCommand) async throws {
        calls += 1
        if calls == 1 {
            try await withCheckedThrowingContinuation { pending = $0 }
        }
    }
    func finishWithFailure() {
        pending?.resume(throwing: TerminalCommandError.automationDenied)
        pending = nil
    }
}

private final class TerminalExecutionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var active = 0
    private var maximumActive = 0
    private var mainThreadCalls = 0
    var snapshot: [Int] { lock.withLock { [calls, maximumActive, mainThreadCalls] } }
    func run() {
        lock.withLock {
            calls += 1
            active += 1
            maximumActive = max(active, maximumActive)
            if Thread.isMainThread { mainThreadCalls += 1 }
        }
        Thread.sleep(forTimeInterval: 0.05)
        lock.withLock { active -= 1 }
    }
}

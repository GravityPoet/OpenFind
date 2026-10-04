import AppKit
import Darwin
import Foundation
import Testing
@testable import OpenFind

@MainActor
@Suite("Terminal Bridge", .serialized)
struct TerminalBridgeTests {
    @Test func anUntrustedParentCannotExecuteAnOtherwiseValidRequest() throws {
        let input = try JSONEncoder().encode(TerminalBridge.Request(target: "terminal", command: "pwd"))
        let response = TerminalBridge.handle(input, trustedParent: false) { _ in
            Issue.record("External caller borrowed Automation consent")
        }
        #expect(response.status == .sendFailed)
        #expect(TerminalBridge.sharesExecutable(with: getpid()))
        #expect(!TerminalBridge.sharesExecutable(with: 0))
    }

    @Test func validatesRequestsBeforeExecutingAnyScript() throws {
        let invalid: [Data] = [
            Data(), Data("{}".utf8), Data(repeating: 65, count: TerminalBridge.maximumRequestBytes + 1),
            try JSONEncoder().encode(TerminalBridge.Request(version: 2, target: "terminal", command: "pwd")),
            try JSONEncoder().encode(TerminalBridge.Request(target: "unknown", command: "pwd")),
            try JSONEncoder().encode(TerminalBridge.Request(target: "systemDefault", command: "pwd")),
            try JSONEncoder().encode(TerminalBridge.Request(target: "terminal", command: "pwd\necho bad"))
        ]
        for data in invalid {
            let response = TerminalBridge.handle(data) { _ in Issue.record("Invalid request executed") }
            #expect(response.status == .invalidCommand)
        }
    }

    @Test func fixedTargetsAndEscapedCommandsSurviveTheProtocol() throws {
        let command = try #require(TerminalCommand(input: "printf '%s' \"中文 \\ $HOME $(printf test)\""))
        for target in TerminalCommandTarget.directTargets {
            let data = try JSONEncoder().encode(TerminalBridge.Request(target: target.rawValue, command: command.text))
            var calls = 0
            let response = TerminalBridge.handle(data) { source in
                calls += 1
                #expect(source == TerminalCommandRunner(target: target).source(for: command))
            }
            #expect(calls == 1)
            #expect(response.status == .delivered)
        }
    }

    @Test func errorsAreTypedAndNeverReturnRawCommands() throws {
        let input = try JSONEncoder().encode(TerminalBridge.Request(target: "terminal", command: "pwd"))
        for (number, expected) in [(-1743, TerminalBridge.Status.automationDenied),
                                   (-1712, .timedOut), (-600, .launchFailed), (-1700, .sendFailed)] {
            let response = TerminalBridge.handle(input) { _ in
                throw TerminalAppleScriptError(number: number, message: "Private command text")
            }
            #expect(response.status == expected)
            #expect(response.errorNumber == number)
            #expect(!String(decoding: try JSONEncoder().encode(response), as: UTF8.self).contains("Private"))
        }
        let disabled = TerminalBridge.handle(input) { _ in
            throw TerminalAppleScriptError(number: -1743, message:
                "AppleScript is disabled by the macos-applescript configuration.")
        }
        #expect(disabled.status == .appleScriptDisabled)
    }

    @Test func realExecutableHandlesInvalidRequestsWithoutStartingTheGUI() async throws {
        let result = try await BoundedProcessRunner.run(
            executableURL: try builtExecutable(), arguments: [TerminalBridge.argument],
            timeout: 3, outputLimit: TerminalBridge.maximumResponseBytes,
            input: Data("{}".utf8), discardStandardError: true
        )
        #expect(result.terminationStatus == 0)
        #expect(!result.timedOut)
        #expect(try JSONDecoder().decode(TerminalBridge.Response.self, from: result.output).status == .invalidCommand)
        // The actual helper must reject a valid request from XCTest, whose
        // kernel executable differs from OpenFind, before touching Apple Events.
        let external = try await BoundedProcessRunner.run(
            executableURL: try builtExecutable(), arguments: [TerminalBridge.argument],
            timeout: 3, outputLimit: TerminalBridge.maximumResponseBytes,
            input: try JSONEncoder().encode(TerminalBridge.Request(target: "terminal", command: "pwd")),
            discardStandardError: true
        )
        #expect(external.terminationStatus == 0)
        #expect(try JSONDecoder().decode(TerminalBridge.Response.self, from: external.output).status == .sendFailed)
    }

    @Test func helperExitsWhenItsParentDiesEvenWithStdinStillOpen() async throws {
        let fixture = try BridgeFixture()
        defer { fixture.remove() }
        let executable = try builtExecutable()
        let quote: (String) -> String = { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let parent = Process()
        let input = Pipe()
        parent.executableURL = URL(fileURLWithPath: "/bin/sh")
        parent.arguments = ["-c", quote(executable.path) + " --terminal-bridge <&0 >/dev/null 2>/dev/null &\n"
            + "printf '%s' \"$!\" > " + quote(fixture.pid.path) + "\nwait\n"]
        parent.standardInput = input
        parent.standardOutput = FileHandle.nullDevice
        parent.standardError = FileHandle.nullDevice
        try parent.run()
        defer {
            if parent.isRunning { parent.terminate(); parent.waitUntilExit() }
            try? input.fileHandleForWriting.close()
            try? input.fileHandleForReading.close()
        }
        try await waitUntil { (try? fixture.blockedPID()) != nil }
        let pid = try fixture.blockedPID()
        // Allow the real entry point to start and block reading the request.
        try await Task.sleep(for: .milliseconds(700))
        #expect(kill(pid, 0) == 0)
        parent.terminate()
        parent.waitUntilExit()
        try await waitUntil { kill(pid, 0) == -1 && errno == ESRCH }
    }

    @Test func timeoutKillsAnUnresponsiveHelperAndImmediatelyReleasesTheLane() async throws {
        let fixture = try BridgeFixture()
        defer { fixture.remove() }
        let runner = makeRunner(fixture)
        let started = ContinuousClock.now
        let delivery = Task {
            // Keep enough startup margin for the full suite's process load;
            // the assertion is about bounded cleanup, not a sub-second SLA.
            try await runner.send(TerminalCommand(input: "blocked")!, timeout: .seconds(2))
        }
        try await waitUntil("blocked helper did not publish its PID") {
            (try? fixture.blockedPID()) != nil
        }
        await #expect(throws: TerminalCommandError.timedOut) { try await delivery.value }
        #expect(ContinuousClock.now - started < .seconds(5))
        let pid = try fixture.blockedPID()
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
        // This target must accept another request without waiting for the old
        // AppleScript or restarting OpenFind; success also proves no retry.
        try await runner.send(TerminalCommand(input: "next")!)
        try await waitUntil("delivery log did not contain blocked followed by next") {
            guard let data = try? Data(contentsOf: fixture.calls) else { return false }
            return String(decoding: data, as: UTF8.self) == "blocked\nnext\n"
        }
        let calls = try Data(contentsOf: fixture.calls)
        #expect(String(decoding: calls, as: UTF8.self) == "blocked\nnext\n")
    }

    @Test func cancellationKillsTheChildBeforeASecondDelivery() async throws {
        let fixture = try BridgeFixture()
        defer { fixture.remove() }
        let runner = makeRunner(fixture)
        let task = Task { try await runner.send(TerminalCommand(input: "blocked")!) }
        try await waitUntil { FileManager.default.fileExists(atPath: fixture.pid.path) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(kill(try fixture.blockedPID(), 0) == -1 && errno == ESRCH)
        try await runner.send(TerminalCommand(input: "next")!)
    }

    @Test func crashAndMalformedRepliesDoNotRetryAndReleaseTheLane() async throws {
        let fixture = try BridgeFixture()
        defer { fixture.remove() }
        let runner = makeRunner(fixture)
        for text in ["crash", "malformed"] {
            await #expect(throws: TerminalCommandError.sendFailed("")) {
                try await runner.send(TerminalCommand(input: text)!)
            }
            try await runner.send(TerminalCommand(input: "next")!)
        }
        let calls = try Data(contentsOf: fixture.calls)
        #expect(String(decoding: calls, as: UTF8.self) == "crash\nnext\nmalformed\nnext\n")
    }

    @Test func panelClosesDuringTimeoutAndCanSendAgainWithoutRestart() async throws {
        _ = NSApplication.shared
        let fixture = try BridgeFixture()
        defer { fixture.remove() }
        let runner = makeRunner(fixture)
        let controller = QuickSearchWindowController(onShowFullSearch: { _ in },
            sendTerminalCommand: { try await runner.send($0, timeout: .milliseconds(500)) })
        defer { controller.close() }
        controller.show()
        controller.viewModel.query = "g blocked"
        try await waitUntil { controller.viewModel.selectedResult != nil }
        controller.panel?.onOpen?()
        try await waitUntil { controller.viewModel.isSendingCommand }
        #expect(!controller.isVisible)
        try await waitUntil { controller.viewModel.errorMessage != nil }
        #expect(controller.isVisible)
        #expect(!controller.viewModel.isSendingCommand)
        #expect(controller.viewModel.query == "g blocked")
        controller.viewModel.query = "g next"
        try await waitUntil { controller.viewModel.resultsAreCurrent && controller.viewModel.selectedResult != nil }
        controller.panel?.onOpen?()
        try await waitUntil { !controller.viewModel.isSendingCommand && !controller.isVisible }
        #expect(try String(contentsOf: fixture.calls, encoding: .utf8) == "blocked\nnext\n")
    }

    private func makeRunner(_ fixture: BridgeFixture) -> TerminalCommandRunner {
        // Use the least-contended direct target so this process-lifecycle
        // fixture cannot race the UI delivery suites, which share the global
        // per-target delivery lane while Swift Testing discovers suites.
        TerminalCommandRunner(target: .iterm2,
            findApplication: { _ in URL(fileURLWithPath: "/Applications/iTerm.app") },
            runBridge: { command, target, timeout in
                let marker = command.text
                try (marker + "\n").append(to: fixture.calls)
                let executable = marker == "blocked" ? fixture.blocked
                    : marker == "crash" ? fixture.crash
                    : marker == "malformed" ? fixture.malformed : fixture.success
                try await TerminalBridge.send(command, target: target, timeout: timeout, executableURL: executable)
            },
            validateApplication: { _, _ in })
    }

    private func builtExecutable() throws -> URL {
        // XCTest's argv[0] can name Xcode's system runner. The resources
        // bundle is beside the SwiftPM product for both debug and release.
        var directory = Bundle.module.bundleURL.deletingLastPathComponent()
        for _ in 0..<8 {
            let executable = directory.appendingPathComponent("OpenFind")
            if FileManager.default.isExecutableFile(atPath: executable.path) { return executable }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private func waitUntil(
        _ description: String = "condition did not become true",
        _ predicate: () -> Bool
    ) async throws {
        for _ in 0..<300 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "TerminalBridgeTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: description])
    }
}

private struct BridgeFixture: Sendable {
    let directory: URL
    let pid: URL
    let calls: URL
    let blocked: URL
    let success: URL
    let crash: URL
    let malformed: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("bridge-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        pid = directory.appendingPathComponent("pid")
        calls = directory.appendingPathComponent("calls")
        blocked = directory.appendingPathComponent("blocked.sh")
        success = directory.appendingPathComponent("success.sh")
        crash = directory.appendingPathComponent("crash.sh")
        malformed = directory.appendingPathComponent("malformed.sh")
        let quotedPID = "'" + pid.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let quotedPIDTemporary = "'" + (pid.path + ".tmp").replacingOccurrences(of: "'", with: "'\\''") + "'"
        // Publish the PID with an atomic rename. A direct redirection creates
        // an empty file first; a concurrent Data(contentsOf:) can observe
        // that transient state under a loaded full-suite run.
        let bodies = [blocked: "printf '%s' \"$$\" > " + quotedPIDTemporary + " && mv " + quotedPIDTemporary + " " + quotedPID + "\ntrap '' TERM\nexec /bin/sleep 30\n",
                      success: "/bin/cat >/dev/null\nprintf '%s' '{\"status\":\"delivered\"}'\n",
                      crash: "/bin/cat >/dev/null\nkill -KILL $$\n",
                      malformed: "/bin/cat >/dev/null\nprintf '%s' '{}'\n"]
        for (url, body) in bodies {
            try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
    }

    func blockedPID() throws -> pid_t {
        let text = String(decoding: try Data(contentsOf: pid), as: UTF8.self)
        return try #require(pid_t(text))
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

private extension String {
    func append(to url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { _ = close(descriptor) }
        let data = Data(utf8)
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let written = Darwin.write(descriptor, base.advanced(by: offset), data.count - offset)
                guard written > 0 else { throw CocoaError(.fileWriteUnknown) }
                offset += written
            }
        }
    }
}

import Foundation
import Testing
@testable import OpenFind

@Suite("Terminal Setup")
struct TerminalSetupTests {
    @Test func newInstallationKeepsTerminalAfterWelcomeCompletes() throws {
        let name = "OpenFindTests.TerminalSetup." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        TerminalCommandTarget.initializeSelection(in: defaults)
        FirstRunGuideStore.markCompleted(defaults: defaults)
        TerminalCommandTarget.initializeSelection(in: defaults)
        #expect(TerminalCommandTarget.load(from: defaults) == .terminal)
    }

    @Test func upgradePreservesImplicitAndExplicitSelections() throws {
        let name = "OpenFindTests.TerminalUpgrade." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        FirstRunGuideStore.markCompleted(defaults: defaults)
        TerminalCommandTarget.initializeSelection(in: defaults)
        #expect(defaults.string(forKey: TerminalCommandTarget.persistenceKey) == "systemDefault")
        for target in TerminalCommandTarget.allCases {
            defaults.set(target.rawValue, forKey: TerminalCommandTarget.persistenceKey)
            TerminalCommandTarget.initializeSelection(in: defaults)
            #expect(TerminalCommandTarget.load(from: defaults) == target)
            try ConfigurationPreferenceKeys.validatePortableValues([TerminalCommandTarget.persistenceKey: target.rawValue])
        }
    }

    @Test func installationValidatesVersionExecutableAndDictionary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = root.appendingPathComponent("Fixture.app")
        let resources = app.appendingPathComponent("Contents/Resources")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let info: [String: String] = [
            "CFBundleIdentifier": "com.mitchellh.ghostty", "CFBundleExecutable": "fixture",
            "CFBundleShortVersionString": "1.3.1", "OSAScriptingDefinition": "Fixture.sdef"
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let executable = macOS.appendingPathComponent("fixture")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let dictionary = resources.appendingPathComponent("Fixture.sdef")
        let commands = ["new tab", "new window", "input text", "send key"]
        try ("<dictionary><suite>" + commands.map { "<command name=\"\($0)\"/>" }.joined() + "</suite></dictionary>")
            .write(to: dictionary, atomically: true, encoding: .utf8)
        #expect(TerminalInstallation(target: .ghostty, url: app).error == nil)
        #expect(TerminalInstallation(target: .ghostty, url: app).version == "1.3.1")
        #expect(TerminalInstallation(target: .iterm2, url: app).error == .terminalUnavailable)
        try "<dictionary/>".write(to: dictionary, atomically: true, encoding: .utf8)
        #expect(TerminalInstallation(target: .ghostty, url: app).error == .scriptingUnavailable("Ghostty"))
        try FileManager.default.removeItem(at: executable)
        #expect(TerminalInstallation(target: .ghostty, url: app).error == .terminalUnavailable)
        #expect(TerminalInstallation(target: .ghostty, url: nil).error == .terminalUnavailable)
    }

    @Test func oldOrUnknownVersionsRequireAnUpdate() {
        for version in [nil, "", "unknown", "1.2.9", "1.0"] as [String?] {
            #expect(TerminalInstallation.compatibilityError(target: .ghostty, version: version) == .updateRequired("Ghostty", "1.3"))
        }
        for version in ["1.3.1", "1.10.0", "2.0.0"] {
            #expect(TerminalInstallation.compatibilityError(target: .ghostty, version: version) == nil)
        }
        #expect(TerminalInstallation.compatibilityError(target: .iterm2, version: "2.9") == .updateRequired("iTerm2", "3.0"))
    }

    @Test func rejectedInstallationNeverReceivesACommand() async {
        let runner = TerminalCommandRunner(target: .ghostty,
            findApplication: { _ in URL(fileURLWithPath: "/nonexistent/fixture.app") },
            runScript: { _ in Issue.record("An incompatible terminal must not receive a command") },
            validateApplication: { _, _ in throw TerminalCommandError.updateRequired("Ghostty", "1.3") })
        await #expect(throws: TerminalCommandError.updateRequired("Ghostty", "1.3")) {
            try await runner.send(TerminalCommand(input: "pwd")!)
        }
    }

    @Test func testRequiresExecutionReceiptNotJustDelivery() async throws {
        let unconfirmed = TerminalCommandRunner(target: .systemDefault, openDefaultCommand: { _ in })
        await #expect(throws: TerminalCommandError.testNotConfirmed) {
            try await unconfirmed.testConnection(timeout: .milliseconds(1))
        }
        let confirmed = TerminalCommandRunner(target: .systemDefault, openDefaultCommand: { command in
            let expression = try NSRegularExpression(pattern: #"printf '%s' '([A-F0-9-]+)' > '([^']+)'"#)
            let match = try #require(expression.firstMatch(in: command.text, range: NSRange(command.text.startIndex..., in: command.text)))
            let nonceRange = try #require(Range(match.range(at: 1), in: command.text))
            let pathRange = try #require(Range(match.range(at: 2), in: command.text))
            let receipt = URL(fileURLWithPath: String(command.text[pathRange]))
            try String(command.text[nonceRange]).write(to: receipt, atomically: true, encoding: .utf8)
        })
        try await confirmed.testConnection()
    }
}

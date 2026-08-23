import Foundation
import Testing
@testable import OpenFind

@MainActor
@Suite("Power Protect Tests")
struct PowerProtectTests {
    @Test func ruleAcceptsOnlySafeUserNamesAndExactCommands() throws {
        let rule = try PowerProtectRule(userName: "test.user-1")
        #expect(rule.contents.hasPrefix(PowerProtectRule.marker))
        #expect(rule.contents.contains("test.user-1 ALL=(root) NOPASSWD:"))
        #expect(rule.contents.contains("/usr/bin/pmset -a disablesleep 1"))
        #expect(rule.contents.contains("/usr/bin/pmset -a disablesleep 0"))
        #expect(!rule.contents.contains("ALL ALL"))

        for invalid in ["", "ALL", "all", "1user", "user name", "user;rm", "user\nroot"] {
            #expect(throws: PowerProtectError.invalidUserName) {
                try PowerProtectRule(userName: invalid)
            }
        }

        #expect(rule.matches(Data(rule.contents.utf8)))
        #expect(!rule.matches(Data((rule.contents
            + "test.user-1 ALL=(root) NOPASSWD: ALL\n").utf8)))
        #expect(!rule.matches(Data(rule.contents.replacingOccurrences(
            of: "test.user-1",
            with: "another-user"
        ).utf8)))
    }

    @Test func generatedTransactionsAreAtomicValidatedAndRollbackCapable() throws {
        let service = SudoersPowerProtectService(environment: [:])
        let rule = try PowerProtectRule(userName: "testuser")
        let install = service.installScript(rule: rule)
        let uninstall = service.uninstallScript(rule: rule)

        for required in [
            "/usr/bin/mktemp",
            "/usr/bin/lockf -t 30 9",
            "/usr/sbin/visudo -cf",
            "/bin/chmod 0440",
            "/usr/sbin/chown root:wheel",
            "/bin/mv -n",
            "installed_identity",
            "committed=1",
        ] {
            #expect(install.contains(required))
        }
        #expect(uninstall.contains("/usr/bin/cmp -s"))
        #expect(uninstall.contains("openfind-remove-backup"))
        #expect(uninstall.contains("/bin/mv -n \"$backup\" \"$target\""))
        #expect(uninstall.contains("removed=1\n/bin/rm -f \"$target\""))
        #expect(!install.contains("testuser ALL="))
        #expect(shellSyntaxIsValid(install))
        #expect(shellSyntaxIsValid(uninstall))
    }

    @Test func installedRuleValidationRequiresExactContentOwnerGroupAndMode() throws {
        let rule = try PowerProtectRule(userName: "testuser")
        let validAttributes: [FileAttributeKey: Any] = [
            .type: FileAttributeType.typeRegular,
            .ownerAccountID: NSNumber(value: 0),
            .groupOwnerAccountID: NSNumber(value: 0),
            .posixPermissions: NSNumber(value: 0o440),
            .size: NSNumber(value: rule.contents.utf8.count),
        ]

        #expect(PowerProtectFileValidator.isValid(
            data: Data(rule.contents.utf8),
            attributes: validAttributes,
            userName: "testuser"
        ))
        #expect(!PowerProtectFileValidator.isValid(
            data: Data((rule.contents + "testuser ALL=(root) NOPASSWD: ALL\n").utf8),
            attributes: validAttributes,
            userName: "testuser"
        ))
        var writableAttributes = validAttributes
        writableAttributes[.posixPermissions] = NSNumber(value: 0o640)
        #expect(!PowerProtectFileValidator.isValid(
            data: Data(rule.contents.utf8),
            attributes: writableAttributes,
            userName: "testuser"
        ))
        #expect(PowerProtectFileValidator.isValid(
            data: nil,
            attributes: validAttributes,
            userName: "testuser"
        ))
        var wrongSizeAttributes = validAttributes
        wrongSizeAttributes[.size] = NSNumber(value: rule.contents.utf8.count + 1)
        #expect(!PowerProtectFileValidator.isValid(
            data: nil,
            attributes: wrongSizeAttributes,
            userName: "testuser"
        ))
    }

    @Test func generatedRulePassesTheSystemVisudoParser() throws {
        let rule = try PowerProtectRule(userName: "openfindtest")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenFind-sudoers-\(UUID())")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(rule.contents.utf8).write(to: url, options: .atomic)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/visudo")
        process.arguments = ["-cf", url.path]
        process.standardOutput = Pipe()
        process.standardError = process.standardOutput
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    @Test func controllerTracksInstallAndUninstallWithoutDuplicateOperations() async throws {
        let service = FakePowerProtectService()
        let controller = PowerProtectController(service: service)
        #expect(controller.state == .notInstalled)

        controller.install()
        try await waitUntil { controller.state == .installed }
        #expect(service.installCount == 1)

        controller.uninstall()
        try await waitUntil { controller.state == .notInstalled }
        #expect(service.uninstallCount == 1)
    }

    @Test func oneTimeAuthorizationInstallsOnceThenUsesOnlyNonInteractiveSudo() async throws {
        let service = FakePowerProtectService()
        let prompt = FakePowerProtectAuthorizationPrompt(choice: .authorize)
        var commands: [(String, [String])] = []
        let client = PMSetClosedDisplayPowerClient(
            powerProtect: service,
            authorizationPrompt: prompt,
            systemPowerAccessAllowed: { true },
            commandRunner: { executable, arguments, _, _ in
                commands.append((executable.path, arguments))
                let output = executable.path == "/usr/bin/pmset"
                    ? Data("SleepDisabled 0\n".utf8)
                    : Data()
                return BoundedProcessResult(
                    output: output,
                    terminationStatus: 0,
                    timedOut: false,
                    outputExceededLimit: false
                )
            }
        )

        try await client.authorizePowerProtectIfNeeded()
        try await client.setSleepDisabled(true)
        try await client.authorizePowerProtectIfNeeded()
        try await client.setSleepDisabled(false)

        #expect(prompt.requestCount == 1)
        #expect(service.installCount == 1)
        #expect(commands.count == 2)
        #expect(commands.first?.0 == "/usr/bin/sudo")
        #expect(commands.first?.1 == ["-n", "/usr/bin/pmset", "-a", "disablesleep", "1"])
        #expect(commands.last?.0 == "/usr/bin/sudo")
        #expect(commands.last?.1 == ["-n", "/usr/bin/pmset", "-a", "disablesleep", "0"])
        #expect(commands.allSatisfy { $0.0 != "/usr/bin/osascript" })
    }

    @Test func backgroundPowerWriteNeverPromptsOrFallsBackToOsascript() async {
        let service = FakePowerProtectService()
        let prompt = FakePowerProtectAuthorizationPrompt(choice: .authorize)
        var commands: [(String, [String])] = []
        let client = PMSetClosedDisplayPowerClient(
            powerProtect: service,
            authorizationPrompt: prompt,
            systemPowerAccessAllowed: { true },
            commandRunner: { executable, arguments, _, _ in
                commands.append((executable.path, arguments))
                return BoundedProcessResult(
                    output: Data(),
                    terminationStatus: 0,
                    timedOut: false,
                    outputExceededLimit: false
                )
            }
        )

        do {
            try await client.setSleepDisabled(true)
            Issue.record("Background power write unexpectedly succeeded without authorization")
        } catch let error as PowerProtectError {
            #expect(error == .authorizationRequired)
        } catch {
            Issue.record("Unexpected background power error: \(error)")
        }

        #expect(prompt.requestCount == 0)
        #expect(service.installCount == 0)
        #expect(commands.isEmpty)
    }

    @Test func revokedInstalledRuleFailsWithoutOpeningAnotherPrompt() async {
        let service = FakePowerProtectService()
        service.currentStatus = .installed
        let prompt = FakePowerProtectAuthorizationPrompt(choice: .authorize)
        var commandCount = 0
        let client = PMSetClosedDisplayPowerClient(
            powerProtect: service,
            authorizationPrompt: prompt,
            systemPowerAccessAllowed: { true },
            commandRunner: { _, _, _, _ in
                commandCount += 1
                return BoundedProcessResult(
                    output: Data("sudo denied".utf8),
                    terminationStatus: 1,
                    timedOut: false,
                    outputExceededLimit: false
                )
            }
        )

        do {
            try await client.setSleepDisabled(true)
            Issue.record("Revoked rule unexpectedly changed system power state")
        } catch is ClosedDisplayPowerError {
            // Expected: surface a recoverable error without another prompt.
        } catch {
            Issue.record("Unexpected revoked-rule error: \(error)")
        }

        #expect(commandCount == 1)
        #expect(prompt.requestCount == 0)
        #expect(service.installCount == 0)
    }

    @Test func cancellingOneTimeAuthorizationDoesNotInstallOrRetry() async {
        let service = FakePowerProtectService()
        let prompt = FakePowerProtectAuthorizationPrompt(choice: .cancel)
        let client = PMSetClosedDisplayPowerClient(
            powerProtect: service,
            authorizationPrompt: prompt,
            systemPowerAccessAllowed: { true }
        )

        do {
            try await client.authorizePowerProtectIfNeeded()
            Issue.record("Cancelled one-time authorization unexpectedly succeeded")
        } catch let error as PowerProtectError {
            #expect(error == .authorizationCancelled)
        } catch {
            Issue.record("Unexpected cancellation error: \(error)")
        }

        #expect(prompt.requestCount == 1)
        #expect(service.installCount == 0)
        #expect(service.currentStatus == .notInstalled)
    }

    @Test func fullClosedDisplayCyclePromptsOnlyOnTheFirstEnable() async throws {
        let suite = "OpenFindTests.OneTimePowerProtect.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = FakePowerProtectService()
        let prompt = FakePowerProtectAuthorizationPrompt(choice: .authorize)
        var sleepDisabled = false
        var sudoValues: [Bool] = []
        let client = PMSetClosedDisplayPowerClient(
            powerProtect: service,
            authorizationPrompt: prompt,
            systemPowerAccessAllowed: { true },
            commandRunner: { executable, arguments, _, _ in
                if executable.path == "/usr/bin/pmset" {
                    return BoundedProcessResult(
                        output: Data("SleepDisabled \(sleepDisabled ? 1 : 0)\n".utf8),
                        terminationStatus: 0,
                        timedOut: false,
                        outputExceededLimit: false
                    )
                }
                let disabled = arguments.last == "1"
                sleepDisabled = disabled
                sudoValues.append(disabled)
                return BoundedProcessResult(
                    output: Data(),
                    terminationStatus: 0,
                    timedOut: false,
                    outputExceededLimit: false
                )
            }
        )
        let controller = ClosedDisplayModeController(
            power: client,
            support: AlwaysSupportedClosedDisplay(),
            defaults: defaults
        )

        try await controller.enable(interaction: .installPowerProtectIfNeeded)
        try await controller.disable(interaction: .installPowerProtectIfNeeded)
        try await controller.enable(interaction: .installPowerProtectIfNeeded)

        #expect(prompt.requestCount == 1)
        #expect(service.installCount == 1)
        #expect(sudoValues == [true, false, true])
        #expect(sleepDisabled)
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }

    private func shellSyntaxIsValid(_ script: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-n", "-c", script]
        process.standardOutput = Pipe()
        process.standardError = process.standardOutput
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

@MainActor
private final class FakePowerProtectService: PowerProtectServicing {
    var currentStatus: PowerProtectInstallationStatus = .notInstalled
    private(set) var installCount = 0
    private(set) var uninstallCount = 0

    func status() -> PowerProtectInstallationStatus { currentStatus }

    func install() async throws {
        installCount += 1
        currentStatus = .installed
    }

    func uninstall() async throws {
        uninstallCount += 1
        currentStatus = .notInstalled
    }
}

@MainActor
private final class FakePowerProtectAuthorizationPrompt: PowerProtectAuthorizationPrompting {
    let choice: PowerProtectAuthorizationChoice
    private(set) var requestCount = 0

    init(choice: PowerProtectAuthorizationChoice) {
        self.choice = choice
    }

    func requestAuthorization() -> PowerProtectAuthorizationChoice {
        requestCount += 1
        return choice
    }
}

private final class AlwaysSupportedClosedDisplay: ClosedDisplaySupportDetecting {
    func supportsClosedDisplayMode() -> Bool { true }
}

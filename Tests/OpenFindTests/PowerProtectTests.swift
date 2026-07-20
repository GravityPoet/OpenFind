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

        for invalid in ["", "1user", "user name", "user;rm", "user\nroot"] {
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
            "/usr/sbin/visudo -cf",
            "/bin/chmod 0440",
            "/usr/sbin/chown root:wheel",
            "/bin/mv -f",
            "openfind-backup",
        ] {
            #expect(install.contains(required))
        }
        #expect(uninstall.contains("/usr/bin/cmp -s"))
        #expect(uninstall.contains("openfind-remove-backup"))
        #expect(uninstall.contains("/bin/mv -f \"$backup\" \"$target\""))
        #expect(!install.contains("testuser ALL="))
    }

    @Test func installedRuleValidationRequiresExactContentOwnerGroupAndMode() throws {
        let rule = try PowerProtectRule(userName: "testuser")
        let validAttributes: [FileAttributeKey: Any] = [
            .type: FileAttributeType.typeRegular,
            .ownerAccountID: NSNumber(value: 0),
            .groupOwnerAccountID: NSNumber(value: 0),
            .posixPermissions: NSNumber(value: 0o440),
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
        let controller = PowerProtectController(service: service, userName: "testuser")
        #expect(controller.state == .notInstalled)

        controller.install()
        try await waitUntil { controller.state == .installed }
        #expect(service.installCount == 1)

        controller.uninstall()
        try await waitUntil { controller.state == .notInstalled }
        #expect(service.uninstallCount == 1)
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
}

@MainActor
private final class FakePowerProtectService: PowerProtectServicing {
    var currentStatus: PowerProtectInstallationStatus = .notInstalled
    private(set) var installCount = 0
    private(set) var uninstallCount = 0

    func status() -> PowerProtectInstallationStatus { currentStatus }

    func install(for userName: String) async throws {
        installCount += 1
        currentStatus = .installed
    }

    func uninstall(for userName: String) async throws {
        uninstallCount += 1
        currentStatus = .notInstalled
    }
}

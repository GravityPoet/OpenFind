import AppKit
import Foundation

@MainActor
protocol ClosedDisplayPowerClient: AnyObject {
    func readSleepDisabled() async throws -> Bool
    func authorizePowerProtectIfNeeded() async throws
    func setSleepDisabled(_ disabled: Bool) async throws
    func setSleepDisabledWithoutPrompt(_ disabled: Bool) async throws -> Bool
}

extension ClosedDisplayPowerClient {
    func authorizePowerProtectIfNeeded() async throws {}
    func setSleepDisabledWithoutPrompt(_ disabled: Bool) async throws -> Bool { false }
}

enum PowerProtectAuthorizationChoice: Equatable {
    case authorize
    case cancel
}

@MainActor
protocol PowerProtectAuthorizationPrompting: AnyObject {
    func requestAuthorization() -> PowerProtectAuthorizationChoice
}

@MainActor
final class SystemPowerProtectAuthorizationPrompt: PowerProtectAuthorizationPrompting {
    func requestAuthorization() -> PowerProtectAuthorizationChoice {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L("Power Protect One-Time Authorization Title")
        alert.informativeText = L("Power Protect One-Time Authorization Body")
        alert.addButton(withTitle: L("Authorize Once and Continue"))
        alert.addButton(withTitle: L("Cancel"))
        return alert.runModal() == .alertFirstButtonReturn ? .authorize : .cancel
    }
}

enum ClosedDisplayPowerError: Error, Equatable, LocalizedError {
    case commandFailed(String)
    case outputInvalid
    case outputTooLarge
    case timedOut
    case testAccessBlocked

    var errorDescription: String? {
        switch self {
        case let .commandFailed(command):
            return "The power-management command failed: \(command)."
        case .outputInvalid:
            return "macOS returned an invalid power-management state."
        case .outputTooLarge:
            return "The power-management command returned too much output."
        case .timedOut:
            return "The power-management command timed out and was stopped."
        case .testAccessBlocked:
            return "System power access is disabled while OpenFind tests are running."
        }
    }
}

struct ClosedDisplayPowerAccessPolicy {
    static let explicitTestModeKey = "OPENFIND_TEST_MODE"
    static let testIntegrationOptInKey = "OPENFIND_ALLOW_REAL_POWER_ACCESS_IN_TESTS"

    static func isAllowed(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        mainBundleURL: URL = Bundle.main.bundleURL,
        executablePath: String = CommandLine.arguments.first ?? ""
    ) -> Bool {
        if environment[testIntegrationOptInKey] == "1" { return true }
        if environment[explicitTestModeKey] == "1" { return false }
        if mainBundleURL.pathExtension == "xctest" { return false }
        if executablePath.contains(".xctest/") || executablePath.hasSuffix(".xctest") {
            return false
        }
        return true
    }
}

struct PMSetOutputParser {
    static func sleepDisabled(from output: String) -> Bool? {
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 2, fields[0] == "SleepDisabled" else { continue }
            switch fields[1] {
            case "0": return false
            case "1": return true
            default: return nil
            }
        }
        return nil
    }
}

@MainActor
final class PMSetClosedDisplayPowerClient: ClosedDisplayPowerClient {
    private static let pmsetPath = "/usr/bin/pmset"
    private static let sudoPath = "/usr/bin/sudo"
    private nonisolated static let maximumOutputBytes = 64 * 1_024
    private let powerProtect: any PowerProtectServicing
    private let authorizationPrompt: any PowerProtectAuthorizationPrompting
    private let systemPowerAccessAllowed: () -> Bool
    private let commandRunner: @MainActor (
        URL,
        [String],
        TimeInterval,
        Int
    ) async throws -> BoundedProcessResult

    init(
        powerProtect: any PowerProtectServicing = SudoersPowerProtectService(),
        authorizationPrompt: any PowerProtectAuthorizationPrompting =
            SystemPowerProtectAuthorizationPrompt(),
        systemPowerAccessAllowed: @escaping () -> Bool = {
            ClosedDisplayPowerAccessPolicy.isAllowed()
        },
        commandRunner: @escaping @MainActor (
            URL,
            [String],
            TimeInterval,
            Int
        ) async throws -> BoundedProcessResult = { executableURL, arguments, timeout, limit in
            try await BoundedProcessRunner.run(
                executableURL: executableURL,
                arguments: arguments,
                timeout: timeout,
                outputLimit: limit
            )
        }
    ) {
        self.powerProtect = powerProtect
        self.authorizationPrompt = authorizationPrompt
        self.systemPowerAccessAllowed = systemPowerAccessAllowed
        self.commandRunner = commandRunner
    }

    func readSleepDisabled() async throws -> Bool {
        guard systemPowerAccessAllowed() else {
            throw ClosedDisplayPowerError.testAccessBlocked
        }
        let output = try await run(
            command: Self.pmsetPath,
            arguments: ["-g"],
            timeout: 5
        )
        guard let value = PMSetOutputParser.sleepDisabled(from: output) else {
            throw ClosedDisplayPowerError.outputInvalid
        }
        return value
    }

    func authorizePowerProtectIfNeeded() async throws {
        guard systemPowerAccessAllowed() else {
            throw ClosedDisplayPowerError.testAccessBlocked
        }
        switch powerProtect.status() {
        case .installed:
            return
        case .notInstalled:
            guard authorizationPrompt.requestAuthorization() == .authorize else {
                throw PowerProtectError.authorizationCancelled
            }
            try await powerProtect.install()
            guard powerProtect.status() == .installed else {
                throw PowerProtectError.commandFailed
            }
        case .invalid:
            throw PowerProtectError.existingRuleInvalid
        case .unsupported:
            throw PowerProtectError.unsupported
        }
    }

    func setSleepDisabled(_ disabled: Bool) async throws {
        guard systemPowerAccessAllowed() else {
            throw ClosedDisplayPowerError.testAccessBlocked
        }
        if try await setSleepDisabledWithoutPrompt(disabled) { return }
        switch powerProtect.status() {
        case .notInstalled:
            throw PowerProtectError.authorizationRequired
        case .invalid:
            throw PowerProtectError.existingRuleInvalid
        case .unsupported:
            throw PowerProtectError.unsupported
        case .installed:
            throw PowerProtectError.commandFailed
        }
    }

    func setSleepDisabledWithoutPrompt(_ disabled: Bool) async throws -> Bool {
        guard systemPowerAccessAllowed() else {
            throw ClosedDisplayPowerError.testAccessBlocked
        }
        guard powerProtect.status() == .installed else { return false }
        let value = disabled ? "1" : "0"
        _ = try await run(
            command: Self.sudoPath,
            arguments: ["-n", Self.pmsetPath, "-a", "disablesleep", value],
            timeout: 10
        )
        return true
    }

    private func run(
        command: String,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> String {
        let result: BoundedProcessResult
        do {
            result = try await commandRunner(
                URL(fileURLWithPath: command),
                arguments,
                timeout,
                Self.maximumOutputBytes
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ClosedDisplayPowerError.commandFailed(command)
        }
        guard !result.timedOut else { throw ClosedDisplayPowerError.timedOut }
        guard !result.outputExceededLimit else {
            throw ClosedDisplayPowerError.outputTooLarge
        }
        guard result.terminationStatus == 0 else {
            throw ClosedDisplayPowerError.commandFailed(command)
        }
        return String(decoding: result.output, as: UTF8.self)
    }
}

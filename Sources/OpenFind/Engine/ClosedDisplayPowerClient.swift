import Foundation

@MainActor
protocol ClosedDisplayPowerClient: AnyObject {
    func readSleepDisabled() async throws -> Bool
    func setSleepDisabled(_ disabled: Bool) async throws
    func setSleepDisabledWithoutPrompt(_ disabled: Bool) async throws -> Bool
}

extension ClosedDisplayPowerClient {
    func setSleepDisabledWithoutPrompt(_ disabled: Bool) async throws -> Bool { false }
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
    private static let osascriptPath = "/usr/bin/osascript"
    private static let sudoPath = "/usr/bin/sudo"
    private nonisolated static let maximumOutputBytes = 64 * 1_024
    private let powerProtect: any PowerProtectServicing
    private let systemPowerAccessAllowed: () -> Bool

    init(
        powerProtect: any PowerProtectServicing = SudoersPowerProtectService(),
        systemPowerAccessAllowed: @escaping () -> Bool = {
            ClosedDisplayPowerAccessPolicy.isAllowed()
        }
    ) {
        self.powerProtect = powerProtect
        self.systemPowerAccessAllowed = systemPowerAccessAllowed
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

    func setSleepDisabled(_ disabled: Bool) async throws {
        guard systemPowerAccessAllowed() else {
            throw ClosedDisplayPowerError.testAccessBlocked
        }
        let value = disabled ? "1" : "0"
        do {
            if try await setSleepDisabledWithoutPrompt(disabled) { return }
        } catch {
            // The rule may have been revoked outside OpenFind. A user-initiated
            // transition can still fall back to the standard admin prompt.
        }
        let script = "do shell script \"/usr/bin/pmset -a disablesleep \(value)\" with administrator privileges"
        _ = try await run(
            command: Self.osascriptPath,
            arguments: ["-e", script],
            timeout: 300
        )
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
            result = try await BoundedProcessRunner.run(
                executableURL: URL(fileURLWithPath: command),
                arguments: arguments,
                timeout: timeout,
                outputLimit: Self.maximumOutputBytes
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

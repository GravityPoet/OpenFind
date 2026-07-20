import AppKit
import Foundation
import Testing
@testable import OpenFind

@MainActor
@Suite("Closed Display Mode Tests")
struct ClosedDisplayModeTests {
    @Test func corruptRecoveryJournalIsNotSilentlyDiscarded() async throws {
        let suite = "OpenFindTests.ClosedDisplay.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("not-json".utf8), forKey: "OpenFind.closedDisplayJournalV1")
        let power = FakeClosedDisplayPower(initial: false)
        let controller = ClosedDisplayModeController(
            power: power,
            support: FakeClosedDisplaySupport(supported: true),
            defaults: defaults
        )

        #expect(await !controller.recoverIfNeeded())
        #expect(controller.hasPendingRestoration)
        #expect(power.writes.isEmpty)
        if case let .error(message) = controller.state {
            #expect(message.contains("recovery record"))
        } else {
            Issue.record("Corrupt journal did not surface an error state")
        }
    }

    @Test func enableAndDisableRestoreTheExactOriginalValue() async throws {
        let defaults = try #require(UserDefaults(suiteName: "OpenFindTests.ClosedDisplay.\(UUID())"))
        let power = FakeClosedDisplayPower(initial: false)
        let controller = ClosedDisplayModeController(
            power: power,
            support: FakeClosedDisplaySupport(supported: true),
            defaults: defaults
        )

        try await controller.enable()
        #expect(power.value)
        try await controller.disable()
        #expect(!power.value)
        #expect(controller.state == .disabled)
        #expect(defaults.data(forKey: "OpenFind.closedDisplayJournalV1") == nil)
    }

    @Test func preexistingSleepDisabledStateNeedsNoRedundantPrivilegedWrites() async throws {
        let defaults = try #require(UserDefaults(
            suiteName: "OpenFindTests.ClosedDisplay.\(UUID())"
        ))
        let power = FakeClosedDisplayPower(initial: true)
        let controller = ClosedDisplayModeController(
            power: power,
            support: FakeClosedDisplaySupport(supported: true),
            defaults: defaults
        )

        try await controller.enable()
        try await controller.disable()

        #expect(power.value)
        #expect(power.writes.isEmpty)
        #expect(!controller.hasPendingRestoration)
    }

    @Test func recoveryRestoresAStaleManagedValueAfterAProcessInterruption() async throws {
        let suiteName = "OpenFindTests.ClosedDisplay.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let power = FakeClosedDisplayPower(initial: false)
        let first = ClosedDisplayModeController(
            power: power,
            support: FakeClosedDisplaySupport(supported: true),
            defaults: defaults
        )
        try await first.enable()
        #expect(power.value)

        let second = ClosedDisplayModeController(
            power: power,
            support: FakeClosedDisplaySupport(supported: true),
            defaults: defaults
        )
        #expect(await second.recoverIfNeeded())

        #expect(!power.value)
        #expect(second.state == .disabled)
    }

    @Test func userChangeIsNotOverwrittenDuringRecovery() async throws {
        let suiteName = "OpenFindTests.ClosedDisplay.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let power = FakeClosedDisplayPower(initial: false)
        let controller = ClosedDisplayModeController(
            power: power,
            support: FakeClosedDisplaySupport(supported: true),
            defaults: defaults
        )
        try await controller.enable()
        power.value = false

        #expect(await controller.recoverIfNeeded())

        #expect(!power.value)
        #expect(defaults.data(forKey: "OpenFind.closedDisplayJournalV1") == nil)
    }

    @Test func powerProtectReappliesManagedStateAfterPowerSourceChange() async throws {
        let defaults = try #require(UserDefaults(
            suiteName: "OpenFindTests.ClosedDisplay.\(UUID())"
        ))
        let power = FakeClosedDisplayPower(initial: false)
        power.allowsPromptlessReapply = true
        let controller = ClosedDisplayModeController(
            power: power,
            support: FakeClosedDisplaySupport(supported: true),
            defaults: defaults
        )
        try await controller.enable()
        power.value = false

        #expect(await controller.reconcileAfterPowerSourceChange())
        #expect(power.value)
        #expect(controller.state == .enabled)
        #expect(power.writes == [true, true])
    }

    @Test func missingPowerProtectFailsClosedWithoutOpeningAnAdminPrompt() async throws {
        let defaults = try #require(UserDefaults(
            suiteName: "OpenFindTests.ClosedDisplay.\(UUID())"
        ))
        let power = FakeClosedDisplayPower(initial: false)
        let controller = ClosedDisplayModeController(
            power: power,
            support: FakeClosedDisplaySupport(supported: true),
            defaults: defaults
        )
        try await controller.enable()
        power.value = false

        #expect(await !controller.reconcileAfterPowerSourceChange())
        #expect(controller.hasPendingRestoration)
        #expect(power.writes == [true])
        if case .error = controller.state {
            // Expected: the session owner will end the session and reconcile
            // the retained journal without showing an unattended prompt.
        } else {
            Issue.record("Power-source reset did not surface a closed-display error")
        }
    }

    @Test func unsupportedMacDoesNotWritePowerState() async {
        let power = FakeClosedDisplayPower(initial: false)
        let controller = ClosedDisplayModeController(
            power: power,
            support: FakeClosedDisplaySupport(supported: false)
        )

        do {
            try await controller.enable()
            Issue.record("Unsupported closed-display mode unexpectedly succeeded")
        } catch let error as ClosedDisplayModeError {
            #expect(error == .unsupported)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(!power.value)
        #expect(controller.state == .unsupported)
    }

    @Test func unsupportedMacWithoutAStaleJournalNeedsNoRecovery() async {
        let controller = ClosedDisplayModeController(
            power: FakeClosedDisplayPower(initial: false),
            support: FakeClosedDisplaySupport(supported: false)
        )

        #expect(await controller.recoverIfNeeded())
        #expect(controller.state == .unsupported)
    }

    @Test func pmsetParserAcceptsOnlyExplicitBinaryValues() {
        #expect(PMSetOutputParser.sleepDisabled(from: "SleepDisabled 1\n") == true)
        #expect(PMSetOutputParser.sleepDisabled(from: "SleepDisabled 0\n") == false)
        #expect(PMSetOutputParser.sleepDisabled(from: "SleepDisabled 2\n") == nil)
        #expect(PMSetOutputParser.sleepDisabled(from: "nothing\n") == nil)
    }

    @Test func supportRequiresBothAnInternalBatteryAndAClamshellProperty() {
        #expect(BatteryBasedClosedDisplaySupportDetector(
            hardware: FakeClosedDisplayHardware(hasBattery: true, state: .open)
        ).supportsClosedDisplayMode())
        #expect(!BatteryBasedClosedDisplaySupportDetector(
            hardware: FakeClosedDisplayHardware(hasBattery: false, state: .open)
        ).supportsClosedDisplayMode())
        #expect(!BatteryBasedClosedDisplaySupportDetector(
            hardware: FakeClosedDisplayHardware(hasBattery: true, state: .unknown)
        ).supportsClosedDisplayMode())
    }

    @Test func stateMonitorEmitsOnlyRealClamshellTransitions() {
        let hardware = MutableClosedDisplayHardware(state: .open)
        let workspaceCenter = NotificationCenter()
        let applicationCenter = NotificationCenter()
        let monitor = SystemClosedDisplayStateMonitor(
            hardware: hardware,
            workspaceCenter: workspaceCenter,
            applicationCenter: applicationCenter
        )
        var states: [ClosedDisplayHardwareState] = []
        monitor.start { states.append($0) }
        defer { monitor.stop() }

        workspaceCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        #expect(states.isEmpty)
        hardware.state = .closed
        workspaceCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspaceCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        #expect(states == [.closed])
        hardware.state = .open
        applicationCenter.post(
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        #expect(states == [.closed, .open])
    }
}

@MainActor
private final class FakeClosedDisplayPower: ClosedDisplayPowerClient {
    var value: Bool
    var allowsPromptlessReapply = false
    private(set) var writes: [Bool] = []
    init(initial: Bool) { value = initial }
    func readSleepDisabled() async throws -> Bool { value }
    func setSleepDisabled(_ disabled: Bool) async throws {
        writes.append(disabled)
        value = disabled
    }
    func setSleepDisabledWithoutPrompt(_ disabled: Bool) async throws -> Bool {
        guard allowsPromptlessReapply else { return false }
        writes.append(disabled)
        value = disabled
        return true
    }
}

private final class FakeClosedDisplaySupport: ClosedDisplaySupportDetecting {
    let supported: Bool
    init(supported: Bool) { self.supported = supported }
    func supportsClosedDisplayMode() -> Bool { supported }
}

private struct FakeClosedDisplayHardware: ClosedDisplayHardwareInspecting {
    let hasBattery: Bool
    let state: ClosedDisplayHardwareState

    func hasInternalBattery() -> Bool { hasBattery }
    func clamshellState() -> ClosedDisplayHardwareState { state }
}

private final class MutableClosedDisplayHardware: @unchecked Sendable, ClosedDisplayHardwareInspecting {
    let hasBattery: Bool
    var state: ClosedDisplayHardwareState

    init(hasBattery: Bool = true, state: ClosedDisplayHardwareState) {
        self.hasBattery = hasBattery
        self.state = state
    }

    func hasInternalBattery() -> Bool { hasBattery }
    func clamshellState() -> ClosedDisplayHardwareState { state }
}

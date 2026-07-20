import Foundation
import Testing
@testable import OpenFind

@MainActor
@Suite("Awake Automation Controller Tests")
struct AwakeAutomationControllerTests {
    @Test func launchAndWakeUseTheConfiguredDefaultRequest() async throws {
        let suite = "OpenFindTests.AwakeAutomation.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AwakeSessionPreferences(defaults: defaults)
        preferences.setDefaultDurationMinutes(30)
        preferences.setStartsSessionAtLaunch(true)
        preferences.setStartsSessionAfterWake(true)
        let sessions = AwakeSessionController(assertions: AutomationPowerAssertions())
        let power = AutomationPowerMonitor()
        let controller = AwakeAutomationController(
            sessions: sessions,
            preferences: preferences,
            workspaceCenter: NotificationCenter(),
            powerMonitor: power,
            lowBatteryPrompt: AutomationLowBatteryPrompt(shouldEnd: true)
        )
        controller.start()
        defer { controller.stop() }

        controller.handleApplicationLaunch()
        try await waitUntil { sessions.activeSession?.source == .applicationLaunch }
        let launchSession = try #require(sessions.activeSession)
        let remaining = try #require(launchSession.remainingTime(at: launchSession.startedAt))
        #expect(abs(remaining - 30 * 60) < 0.001)

        try await sessions.endAsync()
        controller.handleWake()
        try await waitUntil { sessions.activeSession?.source == .wake }
    }

    @Test func forcedSleepEndsManualButNeverTriggerOwnedSessions() async throws {
        let suite = "OpenFindTests.AwakeAutomation.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AwakeSessionPreferences(defaults: defaults)
        preferences.setEndsSessionOnForcedSleep(true)
        let sessions = AwakeSessionController(assertions: AutomationPowerAssertions())
        let controller = AwakeAutomationController(
            sessions: sessions,
            preferences: preferences,
            workspaceCenter: NotificationCenter(),
            powerMonitor: AutomationPowerMonitor(),
            lowBatteryPrompt: AutomationLowBatteryPrompt(shouldEnd: true)
        )

        try sessions.start(.init(source: .trigger(UUID())))
        controller.handleForcedSleep()
        try await Task.sleep(for: .milliseconds(20))
        #expect(sessions.isActive)

        try sessions.start(.init(source: .manual))
        controller.handleForcedSleep()
        try await waitUntil { !sessions.isActive }
    }

    @Test func lowBatteryEndsAndACReconnectRestartsOnlyTheEndedSession() async throws {
        let suite = "OpenFindTests.AwakeAutomation.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AwakeSessionPreferences(defaults: defaults)
        preferences.setLowBatteryEndEnabled(true)
        preferences.setLowBatteryThreshold(20)
        preferences.setIgnoresLowBatteryWhileOnAC(true)
        preferences.setRestartsSessionAfterACReconnect(true)
        let sessions = AwakeSessionController(assertions: AutomationPowerAssertions())
        let power = AutomationPowerMonitor()
        let controller = AwakeAutomationController(
            sessions: sessions,
            preferences: preferences,
            workspaceCenter: NotificationCenter(),
            powerMonitor: power,
            lowBatteryPrompt: AutomationLowBatteryPrompt(shouldEnd: true)
        )
        controller.start()
        defer { controller.stop() }
        try sessions.start(.init(source: .manual))

        power.emit(.init(batteryPercentage: 10, adapterConnected: false))
        try await waitUntil { !sessions.isActive }
        power.emit(.init(batteryPercentage: 10, adapterConnected: true))
        try await waitUntil { sessions.activeSession?.source == .powerAdapter }
    }

    @Test func continuingAfterPromptSuppressesRepeatedLowBatteryPromptsForThatSession() async throws {
        let suite = "OpenFindTests.AwakeAutomation.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AwakeSessionPreferences(defaults: defaults)
        preferences.setLowBatteryEndEnabled(true)
        preferences.setLowBatteryThreshold(20)
        preferences.setPromptsBeforeLowBatteryEnd(true)
        let sessions = AwakeSessionController(assertions: AutomationPowerAssertions())
        let power = AutomationPowerMonitor()
        let prompt = AutomationLowBatteryPrompt(shouldEnd: false)
        let controller = AwakeAutomationController(
            sessions: sessions,
            preferences: preferences,
            workspaceCenter: NotificationCenter(),
            powerMonitor: power,
            lowBatteryPrompt: prompt
        )
        controller.start()
        defer { controller.stop() }
        try sessions.start(.init(source: .manual))

        let lowBattery = PowerSourceSnapshot(batteryPercentage: 10, adapterConnected: false)
        power.emit(lowBattery)
        try await waitUntil { prompt.callCount == 1 }
        power.emit(lowBattery)
        try await Task.sleep(for: .milliseconds(20))

        #expect(prompt.callCount == 1)
        #expect(sessions.isActive)
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

private final class AutomationPowerAssertions: PowerAssertionControlling {
    private(set) var activeConfiguration: PowerAssertionConfiguration?

    func activate(_ configuration: PowerAssertionConfiguration) throws {
        activeConfiguration = configuration
    }

    func deactivate() throws {
        activeConfiguration = nil
    }
}

@MainActor
private final class AutomationPowerMonitor: PowerSourceMonitoring {
    private var handler: (@MainActor (PowerSourceSnapshot) -> Void)?
    private var current = PowerSourceSnapshot(batteryPercentage: 80, adapterConnected: true)

    func start(handler: @escaping @MainActor (PowerSourceSnapshot) -> Void) {
        self.handler = handler
        handler(current)
    }

    func stop() {
        handler = nil
    }

    func snapshot() -> PowerSourceSnapshot { current }

    func emit(_ snapshot: PowerSourceSnapshot) {
        current = snapshot
        handler?(snapshot)
    }
}

@MainActor
private final class AutomationLowBatteryPrompt: LowBatteryPrompting {
    private let shouldEnd: Bool
    private(set) var callCount = 0

    init(shouldEnd: Bool) {
        self.shouldEnd = shouldEnd
    }

    func shouldEndSession(batteryPercentage: Int) async -> Bool {
        callCount += 1
        return shouldEnd
    }
}

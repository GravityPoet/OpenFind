import Foundation
import Testing
@testable import OpenFind

@MainActor
@Suite("Trigger Monitor Scheduler Tests")
struct TriggerMonitorSchedulerTests {
    @Test func wakeEventsReevaluateImmediatelyWithoutWaitingForTheFallbackTimer() async throws {
        let suite = "OpenFindTests.TriggerScheduler.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TriggerStore(defaults: defaults)
        _ = try store.add(AwakeTrigger(name: "Wi-Fi", criteria: [.wifiNetwork("Studio")]))
        let sessions = AwakeSessionController(assertions: SchedulerPowerAssertions())
        let coordinator = TriggerCoordinator(store: store, sessions: sessions)
        let provider = SchedulerSnapshotProvider(snapshot: .init(wifiSSID: "Studio"))
        let events = FakeTriggerWakeEvents()
        let scheduler = TriggerMonitorScheduler(
            coordinator: coordinator,
            provider: provider,
            wakeEvents: events
        )
        scheduler.start(interval: 300)
        defer { scheduler.stop() }
        try await waitUntil { sessions.isActive }

        provider.snapshotValue = .init(wifiSSID: "Elsewhere")
        events.emit()
        try await waitUntil { !sessions.isActive }
        #expect(provider.snapshotCount >= 2)
    }

    @Test func triggerEditsReconfigureOnlyTheRequiredNativeWakeSources() async throws {
        let suite = "OpenFindTests.TriggerScheduler.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TriggerStore(defaults: defaults)
        let trigger = AwakeTrigger(name: "Selective", criteria: [.wifiNetwork("Studio")])
        _ = try store.add(trigger)
        let provider = SchedulerSnapshotProvider(snapshot: .init(wifiSSID: "Elsewhere"))
        let events = FakeTriggerWakeEvents()
        let scheduler = TriggerMonitorScheduler(
            coordinator: TriggerCoordinator(
                store: store,
                sessions: AwakeSessionController(assertions: SchedulerPowerAssertions())
            ),
            provider: provider,
            wakeEvents: events
        )
        scheduler.start(interval: 300)
        defer { scheduler.stop() }

        #expect(events.configurations == [[.wifiNetwork]])
        var edited = trigger
        edited.criteria = [.usbDevice(identifier: "device")]
        try store.update(edited)
        try await waitUntil { events.configurations.last == [.usbDevice] }
        #expect(events.configurations == [[.wifiNetwork], [.usbDevice]])

        store.setEnabled(false)
        try await waitUntil { events.configurations.last == [] }
        #expect(events.configurations.last == [])
    }

    @Test func eventsDuringAnEvaluationCoalesceIntoOneFollowUpRefresh() async throws {
        let suite = "OpenFindTests.TriggerScheduler.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TriggerStore(defaults: defaults)
        _ = try store.add(AwakeTrigger(name: "Wi-Fi", criteria: [.wifiNetwork("Studio")]))
        let coordinator = TriggerCoordinator(
            store: store,
            sessions: AwakeSessionController(assertions: SchedulerPowerAssertions())
        )
        let provider = SchedulerSnapshotProvider(snapshot: .init(wifiSSID: "Studio"))
        let events = FakeTriggerWakeEvents()
        let scheduler = TriggerMonitorScheduler(
            coordinator: coordinator,
            provider: provider,
            wakeEvents: events
        )
        scheduler.start(interval: 300)
        defer { scheduler.stop() }

        events.emit()
        events.emit()
        events.emit()
        try await waitUntil { provider.snapshotCount == 2 }
        try await Task.sleep(for: .milliseconds(20))
        #expect(provider.snapshotCount == 2)
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

private final class SchedulerPowerAssertions: PowerAssertionControlling {
    private(set) var activeConfiguration: PowerAssertionConfiguration?
    func activate(_ configuration: PowerAssertionConfiguration) throws {
        activeConfiguration = configuration
    }
    func deactivate() throws { activeConfiguration = nil }
}

@MainActor
private final class SchedulerSnapshotProvider: TriggerSnapshotProviding {
    var snapshotValue: TriggerSnapshot
    private(set) var snapshotCount = 0

    init(snapshot: TriggerSnapshot) {
        snapshotValue = snapshot
    }

    func snapshot(requiredCriteria: Set<TriggerCriterion.Kind>) -> TriggerSnapshot {
        snapshotCount += 1
        return snapshotValue
    }
}

@MainActor
private final class FakeTriggerWakeEvents: TriggerWakeEventSourcing {
    private var handler: (@MainActor () -> Void)?
    private(set) var configurations: [Set<TriggerCriterion.Kind>] = []
    func start(
        requiredCriteria: Set<TriggerCriterion.Kind>,
        handler: @escaping @MainActor () -> Void
    ) {
        configurations.append(requiredCriteria)
        self.handler = handler
    }
    func stop() { handler = nil }
    func emit() { handler?() }
}

import Foundation
import Testing
@testable import OpenFind

@MainActor
@Suite("Trigger Coordinator Tests")
struct TriggerCoordinatorTests {
    @Test func startsFirstMatchingTriggerAndDoesNotDisturbManualSessions() async throws {
        let suiteName = "OpenFindTests.TriggerCoordinator.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = TriggerStore(defaults: defaults)
        let firstID = try store.add(AwakeTrigger(name: "First", criteria: [.wifiNetwork("Studio")]))
        _ = try store.add(AwakeTrigger(name: "Second", criteria: [.wifiNetwork("Elsewhere")]))
        let sessions = AwakeSessionController(assertions: FakeCoordinatorAssertions())
        let coordinator = TriggerCoordinator(store: store, sessions: sessions)

        await coordinator.evaluate(snapshot: .init(wifiSSID: "Studio"))
        #expect(coordinator.activeTriggerID == firstID)
        #expect(sessions.activeSession?.source == .trigger(firstID))

        try sessions.start(.init(source: .manual))
        await coordinator.evaluate(snapshot: .init(wifiSSID: "Elsewhere"))
        #expect(sessions.activeSession?.source == .manual)
        #expect(coordinator.activeTriggerID == nil)
    }

    @Test func changingMatchReplacesOnlyAnExistingTriggerSession() async throws {
        let suiteName = "OpenFindTests.TriggerCoordinator.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = TriggerStore(defaults: defaults)
        _ = try store.add(AwakeTrigger(name: "First", criteria: [.wifiNetwork("One")]))
        let secondID = try store.add(AwakeTrigger(name: "Second", criteria: [.wifiNetwork("Two")]))
        let sessions = AwakeSessionController(assertions: FakeCoordinatorAssertions())
        let coordinator = TriggerCoordinator(store: store, sessions: sessions)

        await coordinator.evaluate(snapshot: .init(wifiSSID: "One"))
        await coordinator.evaluate(snapshot: .init(wifiSSID: "Two"))

        #expect(coordinator.activeTriggerID == secondID)
        #expect(sessions.activeSession?.source == .trigger(secondID))
    }

    @Test func disablingTriggersEndsOnlyTriggerOwnedSessions() async throws {
        let suiteName = "OpenFindTests.TriggerCoordinator.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = TriggerStore(defaults: defaults)
        _ = try store.add(AwakeTrigger(name: "First", criteria: [.wifiNetwork("One")]))
        let sessions = AwakeSessionController(assertions: FakeCoordinatorAssertions())
        let coordinator = TriggerCoordinator(store: store, sessions: sessions)

        await coordinator.evaluate(snapshot: .init(wifiSSID: "One"))
        store.setEnabled(false)
        await coordinator.evaluate(snapshot: .init(wifiSSID: "One"))
        #expect(!sessions.isActive)

        try sessions.start(.init(source: .manual))
        await coordinator.evaluate(snapshot: .init(wifiSSID: "One"))
        #expect(sessions.activeSession?.source == .manual)
    }

    @Test func closedDisplayTriggerUsesTheTransactionalSessionPath() async throws {
        let suiteName = "OpenFindTests.TriggerCoordinator.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = TriggerStore(defaults: defaults)
        let options = AwakeSessionOptions(
            allowsDisplaySleep: false,
            allowsClosedDisplaySleep: false
        )
        _ = try store.add(AwakeTrigger(
            name: "Docked",
            criteria: [.wifiNetwork("Studio")],
            sessionOptions: options
        ))
        let closedDisplay = FakeCoordinatorClosedDisplay()
        let sessions = AwakeSessionController(
            assertions: FakeCoordinatorAssertions(),
            closedDisplay: closedDisplay
        )
        let coordinator = TriggerCoordinator(store: store, sessions: sessions)

        await coordinator.evaluate(snapshot: .init(wifiSSID: "Studio"))
        #expect(closedDisplay.isEnabled)
        #expect(sessions.isActive)

        store.setEnabled(false)
        await coordinator.evaluate(snapshot: .init(wifiSSID: "Studio"))
        #expect(!closedDisplay.isEnabled)
        #expect(!sessions.isActive)
    }

    @Test func manuallyEndingTriggerSessionDisablesTriggersAndPreventsRestart() async throws {
        let suiteName = "OpenFindTests.TriggerCoordinator.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = TriggerStore(defaults: defaults)
        _ = try store.add(AwakeTrigger(name: "Studio", criteria: [.wifiNetwork("Studio")]))
        let sessions = AwakeSessionController(assertions: FakeCoordinatorAssertions())
        let coordinator = TriggerCoordinator(store: store, sessions: sessions)
        let snapshot = TriggerSnapshot(wifiSSID: "Studio")

        await coordinator.evaluate(snapshot: snapshot)
        try sessions.end(reason: .requested)

        #expect(!store.isEnabled)
        #expect(coordinator.activeTriggerID == nil)
        await coordinator.evaluate(snapshot: snapshot)
        #expect(!sessions.isActive)
    }

    @Test func scriptEndingTriggerSessionPreservesTriggersAndAllowsRestart() async throws {
        let suiteName = "OpenFindTests.TriggerCoordinator.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = TriggerStore(defaults: defaults)
        let triggerID = try store.add(AwakeTrigger(name: "Studio", criteria: [.wifiNetwork("Studio")]))
        let sessions = AwakeSessionController(assertions: FakeCoordinatorAssertions())
        let coordinator = TriggerCoordinator(store: store, sessions: sessions)
        let snapshot = TriggerSnapshot(wifiSSID: "Studio")

        await coordinator.evaluate(snapshot: snapshot)
        #expect(sessions.activeSession?.source == .trigger(triggerID))
        #expect(await sessions.requestEndAsync(reason: .scriptRequested))
        #expect(store.isEnabled)

        await coordinator.evaluate(snapshot: snapshot)
        #expect(sessions.activeSession?.source == .trigger(triggerID))
    }
}

private final class FakeCoordinatorAssertions: PowerAssertionControlling {
    private(set) var activeConfiguration: PowerAssertionConfiguration?

    func activate(_ configuration: PowerAssertionConfiguration) throws {
        activeConfiguration = configuration
    }

    func deactivate() throws {
        activeConfiguration = nil
    }
}

@MainActor
private final class FakeCoordinatorClosedDisplay: ClosedDisplayModeManaging {
    var isEnabled = false
    var hasPendingRestoration: Bool { isEnabled }

    func recoverIfNeeded() async -> Bool { true }
    func enable() async throws { isEnabled = true }
    func disable() async throws { isEnabled = false }
}

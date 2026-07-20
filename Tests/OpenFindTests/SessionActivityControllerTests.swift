import AppKit
import Foundation
import Testing
@testable import OpenFind

@MainActor
@Suite("Session Activity Controller Tests")
struct SessionActivityControllerTests {
    @Test func cursorMovementRunsOnlyDuringAnActiveSession() async throws {
        let suite = "OpenFindTests.SessionActivity.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AwakeSessionPreferences(defaults: defaults)
        preferences.setCursorMovementEnabled(true)
        preferences.setCursorInactivityThresholdSeconds(1)
        let sessions = AwakeSessionController(assertions: ActivityPowerAssertions())
        let performer = FakeSessionActivityPerformer(idle: 10)
        let controller = SessionActivityController(
            sessions: sessions,
            preferences: preferences,
            workspaceCenter: NotificationCenter(),
            performer: performer,
            tickInterval: 0.05
        )
        controller.start()
        defer { controller.stop() }

        try await Task.sleep(for: .milliseconds(80))
        #expect(performer.moveCount == 0)
        try sessions.start(.init())
        try await waitUntil { performer.moveCount == 1 }
        try sessions.end()
        try await Task.sleep(for: .milliseconds(80))
        #expect(performer.moveCount == 1)
    }

    @Test func screenSaverAndAccessibilityGateSystemActions() async throws {
        let suite = "OpenFindTests.SessionActivity.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AwakeSessionPreferences(defaults: defaults)
        preferences.setCursorMovementEnabled(true)
        preferences.setCursorInactivityThresholdSeconds(1)
        let sessions = AwakeSessionController(assertions: ActivityPowerAssertions())
        let performer = FakeSessionActivityPerformer(idle: 10)
        performer.screenSaverActive = true
        let controller = SessionActivityController(
            sessions: sessions,
            preferences: preferences,
            workspaceCenter: NotificationCenter(),
            performer: performer,
            tickInterval: 0.05
        )
        controller.start()
        defer { controller.stop() }
        try sessions.start(.init())

        try await Task.sleep(for: .milliseconds(80))
        #expect(performer.moveCount == 0)
        performer.screenSaverActive = false
        performer.isAccessibilityTrusted = false
        try await Task.sleep(for: .milliseconds(80))
        #expect(performer.moveCount == 0)
        #expect(controller.lastErrorMessage == L("Accessibility Permission Required for Cursor"))
    }

    @Test func inactivityLocksAtMostOncePerSession() async throws {
        let suite = "OpenFindTests.SessionActivity.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AwakeSessionPreferences(defaults: defaults)
        preferences.setScreenLockEnabled(true)
        preferences.setScreenLockInactivityThresholdSeconds(1)
        let sessions = AwakeSessionController(assertions: ActivityPowerAssertions())
        let performer = FakeSessionActivityPerformer(idle: 10)
        let center = NotificationCenter()
        let controller = SessionActivityController(
            sessions: sessions,
            preferences: preferences,
            workspaceCenter: center,
            performer: performer,
            tickInterval: 0.05
        )
        controller.start()
        defer { controller.stop() }
        try sessions.start(.init())

        try await waitUntil { performer.lockCount == 1 }
        center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        try await Task.sleep(for: .milliseconds(80))
        #expect(performer.lockCount == 1)
    }

    @Test func closedDisplayNotificationLocksImmediatelyForClosedDisplaySessions() async throws {
        let suite = "OpenFindTests.SessionActivity.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AwakeSessionPreferences(defaults: defaults)
        preferences.setScreenLockEnabled(true)
        preferences.setScreenLockInactivityThresholdSeconds(600)
        preferences.setLockOnClosedDisplay(true)
        let sessions = AwakeSessionController(
            assertions: ActivityPowerAssertions(),
            closedDisplay: ActivityClosedDisplayManager()
        )
        let performer = FakeSessionActivityPerformer(idle: 0)
        let center = NotificationCenter()
        let closedDisplayState = FakeClosedDisplayStateMonitor()
        let controller = SessionActivityController(
            sessions: sessions,
            preferences: preferences,
            workspaceCenter: center,
            performer: performer,
            closedDisplayState: closedDisplayState,
            tickInterval: 0.05
        )
        controller.start()
        defer { controller.stop() }
        try await sessions.startAsync(.init(options: .init(
            allowsDisplaySleep: false,
            allowsClosedDisplaySleep: false
        )))

        closedDisplayState.emit(.closed)
        closedDisplayState.emit(.closed)
        #expect(performer.lockCount == 1)
    }

    @Test func lockedScreenCanTemporarilyAllowDisplaySleepAndRestoresOnUnlock() async throws {
        let suite = "OpenFindTests.SessionActivity.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AwakeSessionPreferences(defaults: defaults)
        preferences.setScreenLockEnabled(true)
        preferences.setAllowsDisplaySleepWhenLocked(true)
        let assertions = ActivityPowerAssertions()
        let sessions = AwakeSessionController(assertions: assertions)
        let performer = FakeSessionActivityPerformer(idle: 0)
        let controller = SessionActivityController(
            sessions: sessions,
            preferences: preferences,
            workspaceCenter: NotificationCenter(),
            performer: performer,
            tickInterval: 0.01
        )
        controller.start()
        defer { controller.stop() }
        try sessions.start(.init(options: .init(allowsDisplaySleep: false)))

        performer.screenLocked = true
        try await waitUntil { sessions.activeSession?.options.allowsDisplaySleep == true }
        #expect(assertions.activeConfiguration?.allowsDisplaySleep == true)

        performer.screenLocked = false
        try await waitUntil { sessions.activeSession?.options.allowsDisplaySleep == false }
        #expect(assertions.activeConfiguration?.allowsDisplaySleep == false)
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

private final class ActivityPowerAssertions: PowerAssertionControlling {
    private(set) var activeConfiguration: PowerAssertionConfiguration?

    func activate(_ configuration: PowerAssertionConfiguration) throws {
        activeConfiguration = configuration
    }

    func deactivate() throws {
        activeConfiguration = nil
    }
}

@MainActor
private final class FakeClosedDisplayStateMonitor: ClosedDisplayStateMonitoring {
    private var handler: (@MainActor (ClosedDisplayHardwareState) -> Void)?
    private var state: ClosedDisplayHardwareState = .open

    func start(handler: @escaping @MainActor (ClosedDisplayHardwareState) -> Void) {
        self.handler = handler
    }

    func stop() {
        handler = nil
    }

    func currentState() -> ClosedDisplayHardwareState { state }

    func emit(_ state: ClosedDisplayHardwareState) {
        self.state = state
        handler?(state)
    }
}

@MainActor
private final class ActivityClosedDisplayManager: ClosedDisplayModeManaging {
    var isEnabled = false
    var hasPendingRestoration: Bool { isEnabled }

    func recoverIfNeeded() async -> Bool { true }
    func enable() async throws { isEnabled = true }
    func disable() async throws { isEnabled = false }
}

@MainActor
private final class FakeSessionActivityPerformer: SessionActivityPerforming {
    var isAccessibilityTrusted = true
    var screenSaverActive = false
    var screenLocked = false
    var idle: TimeInterval
    private(set) var moveCount = 0
    private(set) var lockCount = 0

    init(idle: TimeInterval) {
        self.idle = idle
    }

    func idleSeconds(useCursorMovement: Bool) -> TimeInterval { idle }
    func isScreenSaverActive() -> Bool { screenSaverActive }
    func isScreenLocked() -> Bool { screenLocked }
    func moveCursor(speed: CursorMovementSpeed) { moveCount += 1 }
    func lockScreen() { lockCount += 1 }
}

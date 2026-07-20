import Foundation
import Testing
@testable import OpenFind

@MainActor
@Suite("OpenFind Scripting Service Tests")
struct OpenFindScriptingServiceTests {
    @Test func parsesAmphetamineStyleSessionOptionsWithStrictBounds() throws {
        let suite = "OpenFindTests.Scripting.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AwakeSessionPreferences(defaults: defaults)

        let timed = try OpenFindScriptingService.sessionRequest(
            options: [
                "duration": 2,
                "interval": "hours",
                "displaySleepAllowed": true,
            ] as NSDictionary,
            preferences: preferences
        )
        #expect(timed.endCondition == .after(2 * 3_600))
        #expect(timed.options.allowsDisplaySleep)
        #expect(timed.source == .appleScript)

        let indefinite = try OpenFindScriptingService.sessionRequest(
            options: ["duration": 0, "interval": 0] as NSDictionary,
            preferences: preferences
        )
        #expect(indefinite.endCondition == .indefinitely)

        #expect(throws: OpenFindScriptError.invalidSessionOptions) {
            try OpenFindScriptingService.sessionRequest(
                options: ["duration": -1, "interval": "minutes"] as NSDictionary,
                preferences: preferences
            )
        }
    }

    @Test func sessionQueriesAndSentinelsMatchThePublishedDictionary() async throws {
        let fixture = try ScriptingFixture()
        defer { fixture.removeDefaults() }

        #expect(!fixture.service.sessionIsActive)
        #expect(fixture.service.sessionTimeRemaining == -3)
        #expect(try await fixture.service.startNewSession(options: nil))
        #expect(fixture.service.sessionTimeRemaining == 0)
        #expect(!fixture.service.sessionIsTrigger)

        #expect(await fixture.service.endSession())
        try fixture.sessions.start(.init(source: .trigger(UUID())))
        #expect(fixture.service.sessionTimeRemaining == -1)
        #expect(fixture.service.sessionIsTrigger)

        try await fixture.sessions.endAsync()
        try fixture.sessions.start(.init(
            endCondition: .at(Date().addingTimeInterval(600)),
            source: .manual
        ))
        #expect(fixture.service.sessionTimeRemaining == -2)
    }

    @Test func displayScreenClosedTriggerAndDriveControlsUpdateLiveState() async throws {
        let fixture = try ScriptingFixture()
        defer { fixture.removeDefaults() }

        try fixture.service.setDisplaySleepAllowed(true)
        fixture.service.setScreenSaverAllowed(true)
        #expect(fixture.preferences.allowsDisplaySleep)
        #expect(fixture.preferences.allowsScreenSaver)
        #expect(await fixture.service.setClosedDisplayModeEnabled(true))
        #expect(fixture.service.closedDisplayModeEnabled)

        await fixture.service.setTriggersEnabled(false)
        #expect(!fixture.service.triggersAreEnabled)
        await fixture.service.setTriggersEnabled(true)
        #expect(fixture.service.triggersAreEnabled)

        await fixture.service.setDriveAliveEnabled(true)
        #expect(fixture.service.driveAliveIsEnabled)
        await fixture.service.setDriveAliveEnabled(false)
        #expect(!fixture.service.driveAliveIsEnabled)
    }
}

@MainActor
private final class ScriptingFixture {
    let suite: String
    let defaults: UserDefaults
    let sessions: AwakeSessionController
    let preferences: AwakeSessionPreferences
    let service: OpenFindScriptingService

    init() throws {
        suite = "OpenFindTests.Scripting.\(UUID())"
        defaults = try #require(UserDefaults(suiteName: suite))
        sessions = AwakeSessionController(
            assertions: ScriptingPowerAssertions(),
            closedDisplay: ScriptingClosedDisplayManager()
        )
        preferences = AwakeSessionPreferences(defaults: defaults)
        let triggerStore = TriggerStore(defaults: defaults)
        let triggerCoordinator = TriggerCoordinator(store: triggerStore, sessions: sessions)
        let driveStore = DriveAliveStore(defaults: defaults)
        let driveController = DriveAliveController(store: driveStore, sessions: sessions)
        service = OpenFindScriptingService(
            sessions: sessions,
            preferences: preferences,
            triggerStore: triggerStore,
            triggerCoordinator: triggerCoordinator,
            driveAliveStore: driveStore,
            driveAlive: driveController
        )
    }

    func removeDefaults() {
        defaults.removePersistentDomain(forName: suite)
    }
}

private final class ScriptingPowerAssertions: PowerAssertionControlling {
    private(set) var activeConfiguration: PowerAssertionConfiguration?
    func activate(_ configuration: PowerAssertionConfiguration) throws {
        activeConfiguration = configuration
    }
    func deactivate() throws { activeConfiguration = nil }
}

@MainActor
private final class ScriptingClosedDisplayManager: ClosedDisplayModeManaging {
    var isEnabled = false
    var hasPendingRestoration: Bool { isEnabled }
    func recoverIfNeeded() async -> Bool { true }
    func enable() async throws { isEnabled = true }
    func disable() async throws { isEnabled = false }
}

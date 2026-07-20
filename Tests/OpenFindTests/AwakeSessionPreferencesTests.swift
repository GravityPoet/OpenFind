import Foundation
import Testing
@testable import OpenFind

@MainActor
@Suite("Awake Session Preferences Tests")
struct AwakeSessionPreferencesTests {
    @Test func defaultsAreConservativeAndChangesPersist() throws {
        let suite = "OpenFindTests.AwakeDefaults.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AwakeSessionPreferences(defaults: defaults)

        #expect(!preferences.allowsDisplaySleep)
        #expect(!preferences.allowsScreenSaver)
        #expect(preferences.allowsClosedDisplaySleep)
        #expect(preferences.defaultDurationMinutes == nil)
        #expect(preferences.endTimeCalculation == .timer)
        #expect(!preferences.showsSessionTimeInMenuBar)
        #expect(preferences.menuBarTimeStyle == .remaining)
        #expect(!preferences.uses24HourClock)
        #expect(!preferences.includesSecondsInMenuBar)
        #expect(!preferences.startsSessionAtLaunch)
        #expect(!preferences.startsSessionAfterWake)
        #expect(!preferences.lowBatteryEndEnabled)
        #expect(preferences.ignoresLowBatteryWhileOnAC)
        #expect(!preferences.cursorMovementEnabled)
        #expect(!preferences.screenLockEnabled)
        #expect(!preferences.allowsDisplaySleepWhenLocked)
        #expect(preferences.sessionOptions == .defaultValue)

        preferences.setAllowsDisplaySleep(true)
        preferences.setAllowsScreenSaver(true)
        preferences.setScreenSaverDelayMinutes(30)
        preferences.setScreenSaverExceptionIdentifiers([
            "com.example.Reader",
            "  com.example.Video  ",
            "",
        ])
        preferences.setAllowsClosedDisplaySleep(false)
        preferences.setDefaultDurationMinutes(90)
        preferences.setEndTimeCalculation(.systemClock)
        preferences.setShowsSessionTimeInMenuBar(true)
        preferences.setMenuBarTimeStyle(.endTime)
        preferences.setUses24HourClock(true)
        preferences.setIncludesSecondsInMenuBar(true)
        preferences.setStartsSessionAtLaunch(true)
        preferences.setStartsSessionAfterWake(true)
        preferences.setEndsSessionOnForcedSleep(true)
        preferences.setEndsSessionOnSessionResign(true)
        preferences.setLowBatteryEndEnabled(true)
        preferences.setLowBatteryThreshold(15)
        preferences.setPromptsBeforeLowBatteryEnd(true)
        preferences.setIgnoresLowBatteryWhileOnAC(false)
        preferences.setRestartsSessionAfterACReconnect(true)
        preferences.setCursorMovementEnabled(true)
        preferences.setCursorMovementIntervalSeconds(45)
        preferences.setCursorInactivityThresholdSeconds(120)
        preferences.setCursorStopAfterSeconds(600)
        preferences.setCursorMovementSpeed(.fast)
        preferences.setScreenLockEnabled(true)
        preferences.setScreenLockInactivityThresholdSeconds(300)
        preferences.setLockUsesCursorMovement(true)
        preferences.setLockOnClosedDisplay(true)
        preferences.setAllowsDisplaySleepWhenLocked(true)

        let reloaded = AwakeSessionPreferences(defaults: defaults)
        #expect(reloaded.allowsDisplaySleep)
        #expect(reloaded.allowsScreenSaver)
        #expect(reloaded.screenSaverDelayMinutes == 30)
        #expect(reloaded.screenSaverExceptionIdentifiers == [
            "com.example.Reader",
            "com.example.Video",
        ])
        #expect(!reloaded.allowsClosedDisplaySleep)
        #expect(reloaded.defaultDurationMinutes == 90)
        #expect(reloaded.defaultEndCondition == .after(90 * 60))
        #expect(reloaded.endTimeCalculation == .systemClock)
        #expect(reloaded.showsSessionTimeInMenuBar)
        #expect(reloaded.menuBarTimeStyle == .endTime)
        #expect(reloaded.uses24HourClock)
        #expect(reloaded.includesSecondsInMenuBar)
        #expect(reloaded.startsSessionAtLaunch)
        #expect(reloaded.startsSessionAfterWake)
        #expect(reloaded.endsSessionOnForcedSleep)
        #expect(reloaded.endsSessionOnSessionResign)
        #expect(reloaded.lowBatteryEndEnabled)
        #expect(reloaded.lowBatteryThreshold == 15)
        #expect(reloaded.promptsBeforeLowBatteryEnd)
        #expect(!reloaded.ignoresLowBatteryWhileOnAC)
        #expect(reloaded.restartsSessionAfterACReconnect)
        #expect(reloaded.cursorMovementEnabled)
        #expect(reloaded.cursorMovementIntervalSeconds == 45)
        #expect(reloaded.cursorInactivityThresholdSeconds == 120)
        #expect(reloaded.cursorStopAfterSeconds == 600)
        #expect(reloaded.cursorMovementSpeed == .fast)
        #expect(reloaded.screenLockEnabled)
        #expect(reloaded.screenLockInactivityThresholdSeconds == 300)
        #expect(reloaded.lockUsesCursorMovement)
        #expect(reloaded.lockOnClosedDisplay)
        #expect(reloaded.allowsDisplaySleepWhenLocked)
        #expect(reloaded.sessionOptions == AwakeSessionOptions(
            allowsDisplaySleep: true,
            screenSaverPolicy: .allow(after: 30 * 60),
            screenSaverExceptionIdentifiers: [
                "com.example.Reader",
                "com.example.Video",
            ],
            allowsClosedDisplaySleep: false,
            endTimeCalculation: .systemClock
        ))
    }

    @Test func screenSaverDelayIsClampedToOneDay() throws {
        let suite = "OpenFindTests.AwakeDefaults.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AwakeSessionPreferences(defaults: defaults)

        preferences.setScreenSaverDelayMinutes(-1)
        #expect(preferences.screenSaverDelayMinutes == 0)
        preferences.setScreenSaverDelayMinutes(10_000)
        #expect(preferences.screenSaverDelayMinutes == 1_440)
    }

    @Test func legacySessionOptionsDecodeWithEmptyScreenSaverExceptions() throws {
        let options = AwakeSessionOptions(
            allowsDisplaySleep: true,
            screenSaverPolicy: .allow(after: 90),
            screenSaverExceptionIdentifiers: ["com.example.Reader"],
            allowsClosedDisplaySleep: false
        )
        let encoded = try JSONEncoder().encode(options)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "screenSaverExceptionIdentifiers")
        object.removeValue(forKey: "endTimeCalculation")
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(AwakeSessionOptions.self, from: legacy)
        #expect(decoded.screenSaverExceptionIdentifiers.isEmpty)
        #expect(decoded.allowsDisplaySleep)
        #expect(!decoded.allowsClosedDisplaySleep)
        #expect(decoded.endTimeCalculation == .timer)
    }
}

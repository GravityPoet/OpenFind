import CoreGraphics
import Foundation
import Observation

@MainActor
@Observable
final class AwakeSessionPreferences {
    private static let displaySleepKey = "OpenFind.awakeDefaults.allowDisplaySleepV1"
    private static let screenSaverKey = "OpenFind.awakeDefaults.allowScreenSaverV1"
    private static let screenSaverDelayKey = "OpenFind.awakeDefaults.screenSaverDelayMinutesV1"
    private static let screenSaverExceptionsKey = "OpenFind.awakeDefaults.screenSaverExceptionsV1"
    private static let closedDisplaySleepKey = "OpenFind.awakeDefaults.allowClosedDisplaySleepV1"
    private static let defaultDurationKey = "OpenFind.awakeDefaults.durationMinutesV1"
    private static let endTimeCalculationKey = "OpenFind.awakeDefaults.endTimeCalculationV1"
    private static let showSessionTimeKey = "OpenFind.awakeMenuBar.showSessionTimeV1"
    private static let menuBarTimeStyleKey = "OpenFind.awakeMenuBar.timeStyleV1"
    private static let use24HourClockKey = "OpenFind.awakeMenuBar.use24HourClockV1"
    private static let includeSecondsKey = "OpenFind.awakeMenuBar.includeSecondsV1"
    private static let startAtLaunchKey = "OpenFind.awakeAutomation.startAtLaunchV1"
    private static let startAfterWakeKey = "OpenFind.awakeAutomation.startAfterWakeV1"
    private static let endOnForcedSleepKey = "OpenFind.awakeAutomation.endOnForcedSleepV1"
    private static let endOnSessionResignKey = "OpenFind.awakeAutomation.endOnSessionResignV1"
    private static let lowBatteryEnabledKey = "OpenFind.awakeAutomation.lowBatteryEnabledV1"
    private static let lowBatteryThresholdKey = "OpenFind.awakeAutomation.lowBatteryThresholdV1"
    private static let promptBeforeLowBatteryEndKey = "OpenFind.awakeAutomation.promptLowBatteryV1"
    private static let ignoreLowBatteryOnACKey = "OpenFind.awakeAutomation.ignoreLowBatteryOnACV1"
    private static let restartAfterACKey = "OpenFind.awakeAutomation.restartAfterACV1"
    private static let cursorEnabledKey = "OpenFind.awakeActivity.cursorEnabledV1"
    private static let cursorIntervalKey = "OpenFind.awakeActivity.cursorIntervalSecondsV1"
    private static let cursorInactivityKey = "OpenFind.awakeActivity.cursorInactivitySecondsV1"
    private static let cursorStopAfterKey = "OpenFind.awakeActivity.cursorStopAfterSecondsV1"
    private static let cursorSpeedKey = "OpenFind.awakeActivity.cursorSpeedV1"
    private static let screenLockEnabledKey = "OpenFind.awakeActivity.screenLockEnabledV1"
    private static let screenLockInactivityKey = "OpenFind.awakeActivity.screenLockInactivitySecondsV1"
    private static let lockUsesCursorKey = "OpenFind.awakeActivity.lockUsesCursorMovementV1"
    private static let lockOnClosedDisplayKey = "OpenFind.awakeActivity.lockOnClosedDisplayV1"
    private static let allowDisplaySleepWhenLockedKey = "OpenFind.awakeActivity.allowDisplaySleepWhenLockedV1"
    @ObservationIgnored private let defaults: UserDefaults

    private(set) var allowsDisplaySleep: Bool
    private(set) var allowsScreenSaver: Bool
    private(set) var screenSaverDelayMinutes: Int
    private(set) var screenSaverExceptionIdentifiers: Set<String>
    private(set) var allowsClosedDisplaySleep: Bool
    private(set) var defaultDurationMinutes: Int?
    private(set) var endTimeCalculation: AwakeEndTimeCalculation
    private(set) var showsSessionTimeInMenuBar: Bool
    private(set) var menuBarTimeStyle: AwakeMenuBarTimeStyle
    private(set) var uses24HourClock: Bool
    private(set) var includesSecondsInMenuBar: Bool
    private(set) var startsSessionAtLaunch: Bool
    private(set) var startsSessionAfterWake: Bool
    private(set) var endsSessionOnForcedSleep: Bool
    private(set) var endsSessionOnSessionResign: Bool
    private(set) var lowBatteryEndEnabled: Bool
    private(set) var lowBatteryThreshold: Int
    private(set) var promptsBeforeLowBatteryEnd: Bool
    private(set) var ignoresLowBatteryWhileOnAC: Bool
    private(set) var restartsSessionAfterACReconnect: Bool
    private(set) var cursorMovementEnabled: Bool
    private(set) var cursorMovementIntervalSeconds: Int
    private(set) var cursorInactivityThresholdSeconds: Int
    private(set) var cursorStopAfterSeconds: Int?
    private(set) var cursorMovementSpeed: CursorMovementSpeed
    private(set) var screenLockEnabled: Bool
    private(set) var screenLockInactivityThresholdSeconds: Int
    private(set) var lockUsesCursorMovement: Bool
    private(set) var lockOnClosedDisplay: Bool
    private(set) var allowsDisplaySleepWhenLocked: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        allowsDisplaySleep = defaults.object(forKey: Self.displaySleepKey) as? Bool ?? false
        allowsScreenSaver = defaults.object(forKey: Self.screenSaverKey) as? Bool ?? false
        let storedDelay = defaults.object(forKey: Self.screenSaverDelayKey) as? Int ?? 15
        screenSaverDelayMinutes = min(1_440, max(0, storedDelay))
        screenSaverExceptionIdentifiers = Self.normalizedIdentifiers(
            defaults.stringArray(forKey: Self.screenSaverExceptionsKey) ?? []
        )
        allowsClosedDisplaySleep = defaults.object(forKey: Self.closedDisplaySleepKey) as? Bool ?? true
        let storedDuration = defaults.object(forKey: Self.defaultDurationKey) as? Int ?? 0
        defaultDurationMinutes = storedDuration > 0
            ? min(7 * 24 * 60, max(1, storedDuration)) : nil
        endTimeCalculation = AwakeEndTimeCalculation(rawValue: defaults.string(
            forKey: Self.endTimeCalculationKey
        ) ?? "timer") ?? .timer
        showsSessionTimeInMenuBar = defaults.bool(forKey: Self.showSessionTimeKey)
        menuBarTimeStyle = AwakeMenuBarTimeStyle(rawValue: defaults.string(
            forKey: Self.menuBarTimeStyleKey
        ) ?? "remaining") ?? .remaining
        uses24HourClock = defaults.bool(forKey: Self.use24HourClockKey)
        includesSecondsInMenuBar = defaults.bool(forKey: Self.includeSecondsKey)
        startsSessionAtLaunch = defaults.bool(forKey: Self.startAtLaunchKey)
        startsSessionAfterWake = defaults.bool(forKey: Self.startAfterWakeKey)
        endsSessionOnForcedSleep = defaults.bool(forKey: Self.endOnForcedSleepKey)
        endsSessionOnSessionResign = defaults.bool(forKey: Self.endOnSessionResignKey)
        lowBatteryEndEnabled = defaults.bool(forKey: Self.lowBatteryEnabledKey)
        let storedThreshold = defaults.object(forKey: Self.lowBatteryThresholdKey) as? Int ?? 20
        lowBatteryThreshold = min(100, max(1, storedThreshold))
        promptsBeforeLowBatteryEnd = defaults.bool(forKey: Self.promptBeforeLowBatteryEndKey)
        ignoresLowBatteryWhileOnAC = defaults.object(forKey: Self.ignoreLowBatteryOnACKey) as? Bool
            ?? true
        restartsSessionAfterACReconnect = defaults.bool(forKey: Self.restartAfterACKey)
        cursorMovementEnabled = defaults.bool(forKey: Self.cursorEnabledKey)
        let storedCursorInterval = defaults.object(forKey: Self.cursorIntervalKey) as? Int ?? 60
        cursorMovementIntervalSeconds = min(3_600, max(5, storedCursorInterval))
        let storedCursorInactivity = defaults.object(forKey: Self.cursorInactivityKey) as? Int ?? 60
        cursorInactivityThresholdSeconds = min(86_400, max(1, storedCursorInactivity))
        let storedCursorStop = defaults.object(forKey: Self.cursorStopAfterKey) as? Int ?? 0
        cursorStopAfterSeconds = storedCursorStop > 0
            ? min(86_400, max(1, storedCursorStop)) : nil
        cursorMovementSpeed = CursorMovementSpeed(rawValue: defaults.string(
            forKey: Self.cursorSpeedKey
        ) ?? "normal") ?? .normal
        screenLockEnabled = defaults.bool(forKey: Self.screenLockEnabledKey)
        let storedLockInactivity = defaults.object(forKey: Self.screenLockInactivityKey) as? Int ?? 300
        screenLockInactivityThresholdSeconds = min(86_400, max(1, storedLockInactivity))
        lockUsesCursorMovement = defaults.bool(forKey: Self.lockUsesCursorKey)
        lockOnClosedDisplay = defaults.bool(forKey: Self.lockOnClosedDisplayKey)
        allowsDisplaySleepWhenLocked = defaults.bool(
            forKey: Self.allowDisplaySleepWhenLockedKey
        )
    }

    var sessionOptions: AwakeSessionOptions {
        AwakeSessionOptions(
            allowsDisplaySleep: allowsDisplaySleep,
            screenSaverPolicy: allowsScreenSaver
                ? .allow(after: TimeInterval(screenSaverDelayMinutes * 60))
                : .prevent,
            screenSaverExceptionIdentifiers: screenSaverExceptionIdentifiers,
            allowsClosedDisplaySleep: allowsClosedDisplaySleep,
            endTimeCalculation: endTimeCalculation
        )
    }

    var defaultEndCondition: AwakeSessionEndCondition {
        guard let defaultDurationMinutes else { return .indefinitely }
        return .after(TimeInterval(defaultDurationMinutes * 60))
    }

    func defaultRequest(source: AwakeSessionSource = .manual) -> AwakeSessionRequest {
        AwakeSessionRequest(
            endCondition: defaultEndCondition,
            options: sessionOptions,
            source: source
        )
    }

    func setAllowsDisplaySleep(_ allowed: Bool) {
        allowsDisplaySleep = allowed
        defaults.set(allowed, forKey: Self.displaySleepKey)
    }

    func setAllowsScreenSaver(_ allowed: Bool) {
        allowsScreenSaver = allowed
        defaults.set(allowed, forKey: Self.screenSaverKey)
    }

    func setScreenSaverDelayMinutes(_ minutes: Int) {
        let normalized = min(1_440, max(0, minutes))
        screenSaverDelayMinutes = normalized
        defaults.set(normalized, forKey: Self.screenSaverDelayKey)
    }

    func setScreenSaverExceptionIdentifiers(_ identifiers: Set<String>) {
        screenSaverExceptionIdentifiers = Self.normalizedIdentifiers(Array(identifiers))
        defaults.set(
            screenSaverExceptionIdentifiers.sorted(),
            forKey: Self.screenSaverExceptionsKey
        )
    }

    func setAllowsClosedDisplaySleep(_ allowed: Bool) {
        allowsClosedDisplaySleep = allowed
        defaults.set(allowed, forKey: Self.closedDisplaySleepKey)
    }

    func setDefaultDurationMinutes(_ minutes: Int?) {
        defaultDurationMinutes = minutes.map { min(7 * 24 * 60, max(1, $0)) }
        defaults.set(defaultDurationMinutes ?? 0, forKey: Self.defaultDurationKey)
    }

    func setEndTimeCalculation(_ calculation: AwakeEndTimeCalculation) {
        endTimeCalculation = calculation
        defaults.set(calculation.rawValue, forKey: Self.endTimeCalculationKey)
    }

    func setShowsSessionTimeInMenuBar(_ shown: Bool) {
        showsSessionTimeInMenuBar = shown
        defaults.set(shown, forKey: Self.showSessionTimeKey)
    }

    func setMenuBarTimeStyle(_ style: AwakeMenuBarTimeStyle) {
        menuBarTimeStyle = style
        defaults.set(style.rawValue, forKey: Self.menuBarTimeStyleKey)
    }

    func setUses24HourClock(_ enabled: Bool) {
        uses24HourClock = enabled
        defaults.set(enabled, forKey: Self.use24HourClockKey)
    }

    func setIncludesSecondsInMenuBar(_ enabled: Bool) {
        includesSecondsInMenuBar = enabled
        defaults.set(enabled, forKey: Self.includeSecondsKey)
    }

    func setStartsSessionAtLaunch(_ enabled: Bool) {
        startsSessionAtLaunch = enabled
        defaults.set(enabled, forKey: Self.startAtLaunchKey)
    }

    func setStartsSessionAfterWake(_ enabled: Bool) {
        startsSessionAfterWake = enabled
        defaults.set(enabled, forKey: Self.startAfterWakeKey)
    }

    func setEndsSessionOnForcedSleep(_ enabled: Bool) {
        endsSessionOnForcedSleep = enabled
        defaults.set(enabled, forKey: Self.endOnForcedSleepKey)
    }

    func setEndsSessionOnSessionResign(_ enabled: Bool) {
        endsSessionOnSessionResign = enabled
        defaults.set(enabled, forKey: Self.endOnSessionResignKey)
    }

    func setLowBatteryEndEnabled(_ enabled: Bool) {
        lowBatteryEndEnabled = enabled
        defaults.set(enabled, forKey: Self.lowBatteryEnabledKey)
    }

    func setLowBatteryThreshold(_ percentage: Int) {
        lowBatteryThreshold = min(100, max(1, percentage))
        defaults.set(lowBatteryThreshold, forKey: Self.lowBatteryThresholdKey)
    }

    func setPromptsBeforeLowBatteryEnd(_ enabled: Bool) {
        promptsBeforeLowBatteryEnd = enabled
        defaults.set(enabled, forKey: Self.promptBeforeLowBatteryEndKey)
    }

    func setIgnoresLowBatteryWhileOnAC(_ enabled: Bool) {
        ignoresLowBatteryWhileOnAC = enabled
        defaults.set(enabled, forKey: Self.ignoreLowBatteryOnACKey)
    }

    func setRestartsSessionAfterACReconnect(_ enabled: Bool) {
        restartsSessionAfterACReconnect = enabled
        defaults.set(enabled, forKey: Self.restartAfterACKey)
    }

    func setCursorMovementEnabled(_ enabled: Bool) {
        cursorMovementEnabled = enabled
        defaults.set(enabled, forKey: Self.cursorEnabledKey)
    }

    func setCursorMovementIntervalSeconds(_ seconds: Int) {
        cursorMovementIntervalSeconds = min(3_600, max(5, seconds))
        defaults.set(cursorMovementIntervalSeconds, forKey: Self.cursorIntervalKey)
    }

    func setCursorInactivityThresholdSeconds(_ seconds: Int) {
        cursorInactivityThresholdSeconds = min(86_400, max(1, seconds))
        defaults.set(cursorInactivityThresholdSeconds, forKey: Self.cursorInactivityKey)
    }

    func setCursorStopAfterSeconds(_ seconds: Int?) {
        cursorStopAfterSeconds = seconds.map { min(86_400, max(1, $0)) }
        defaults.set(cursorStopAfterSeconds ?? 0, forKey: Self.cursorStopAfterKey)
    }

    func setCursorMovementSpeed(_ speed: CursorMovementSpeed) {
        cursorMovementSpeed = speed
        defaults.set(speed.rawValue, forKey: Self.cursorSpeedKey)
    }

    func setScreenLockEnabled(_ enabled: Bool) {
        screenLockEnabled = enabled
        defaults.set(enabled, forKey: Self.screenLockEnabledKey)
    }

    func setScreenLockInactivityThresholdSeconds(_ seconds: Int) {
        screenLockInactivityThresholdSeconds = min(86_400, max(1, seconds))
        defaults.set(screenLockInactivityThresholdSeconds, forKey: Self.screenLockInactivityKey)
    }

    func setLockUsesCursorMovement(_ enabled: Bool) {
        lockUsesCursorMovement = enabled
        defaults.set(enabled, forKey: Self.lockUsesCursorKey)
    }

    func setLockOnClosedDisplay(_ enabled: Bool) {
        lockOnClosedDisplay = enabled
        defaults.set(enabled, forKey: Self.lockOnClosedDisplayKey)
    }

    func setAllowsDisplaySleepWhenLocked(_ enabled: Bool) {
        allowsDisplaySleepWhenLocked = enabled
        defaults.set(enabled, forKey: Self.allowDisplaySleepWhenLockedKey)
    }

    private static func normalizedIdentifiers(_ identifiers: [String]) -> Set<String> {
        Set(identifiers.compactMap { value in
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty,
                  normalized.utf8.count <= 512,
                  normalized.unicodeScalars.allSatisfy({
                      !CharacterSet.controlCharacters.contains($0)
                  }) else { return nil }
            return normalized
        }.prefix(128))
    }
}

enum AwakeMenuBarTimeStyle: String, CaseIterable, Sendable {
    case remaining
    case endTime
}

enum CursorMovementSpeed: String, CaseIterable, Sendable {
    case slow
    case normal
    case fast

    var step: CGFloat {
        switch self {
        case .slow: 1
        case .normal: 3
        case .fast: 8
        }
    }
}

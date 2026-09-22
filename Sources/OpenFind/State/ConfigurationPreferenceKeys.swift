import Foundation

enum ConfigurationPreferenceKeys {
    static let all: Set<String> = {
        var keys = [
            "search.target", "search.matchMode", "search.caseSensitive", "search.includeHidden",
            "search.includePackages", "search.deepIndex", "search.maxContentFileSize",
            "search.maxContentIndexBytes", "search.useFrequencyRanking", "OpenFind.clipboardPreferencesV3",
            "OpenFind.clipboardShortcut.keyCodeV1", "OpenFind.clipboardShortcut.modifiersV1",
            "OpenFind.clipboardShortcut.labelV1", "OpenFind.clipboardShortcut.enabledV1",
            "OpenFind.globalHotKeyEnabled", "OpenFind.globalHotKeyKeyCode",
            "OpenFind.globalHotKeyModifiers", "OpenFind.globalHotKeyLabel",
            "OpenFind.quickSearchTriggerV1", "OpenFind.keyboardLockAutoUnlockMinutesV1",
            "OpenFind.keyboardLockPanelOpacityV1",
            "OpenFind.keyboardLockShortcut.keyCodeV1", "OpenFind.keyboardLockShortcut.modifiersV1",
            "OpenFind.keyboardLockShortcut.labelV1", "OpenFind.driveAliveEnabledV1",
            "OpenFind.driveAliveIntervalV1", "OpenFind.awakeTriggersEnabledV1",
            "OpenFind.awakeTriggersV1", "OpenFind.interfaceSizeV1",
        ]
        for action in AwakeHotKeyAction.allCases {
            let prefix = "OpenFind.awakeHotKeyV1.\(action.rawValue)."
            keys += [prefix + "enabled", prefix + "keyCode", prefix + "modifiers", prefix + "label"]
        }
        keys += [
            "OpenFind.awakeDefaults.allowDisplaySleepV1",
            "OpenFind.awakeDefaults.allowScreenSaverV1",
            "OpenFind.awakeDefaults.screenSaverDelayMinutesV1",
            "OpenFind.awakeDefaults.screenSaverExceptionsV1",
            "OpenFind.awakeDefaults.allowClosedDisplaySleepV1",
            "OpenFind.awakeDefaults.durationMinutesV1",
            "OpenFind.awakeDefaults.endTimeCalculationV1",
            "OpenFind.awakeMenuBar.showSessionTimeV1",
            "OpenFind.awakeMenuBar.timeStyleV1",
            "OpenFind.awakeMenuBar.use24HourClockV1",
            "OpenFind.awakeMenuBar.includeSecondsV1",
            "OpenFind.awakeAutomation.startAtLaunchV1",
            "OpenFind.awakeAutomation.startAfterWakeV1",
            "OpenFind.awakeAutomation.endOnForcedSleepV1",
            "OpenFind.awakeAutomation.endOnSessionResignV1",
            "OpenFind.awakeAutomation.lowBatteryEnabledV1",
            "OpenFind.awakeAutomation.lowBatteryThresholdV1",
            "OpenFind.awakeAutomation.promptLowBatteryV1",
            "OpenFind.awakeAutomation.ignoreLowBatteryOnACV1",
            "OpenFind.awakeAutomation.restartAfterACV1",
            "OpenFind.awakeActivity.cursorEnabledV1",
            "OpenFind.awakeActivity.cursorIntervalSecondsV1",
            "OpenFind.awakeActivity.cursorInactivitySecondsV1",
            "OpenFind.awakeActivity.cursorStopAfterSecondsV1",
            "OpenFind.awakeActivity.cursorSpeedV1",
            "OpenFind.awakeActivity.screenLockEnabledV1",
            "OpenFind.awakeActivity.screenLockInactivitySecondsV1",
            "OpenFind.awakeActivity.lockUsesCursorMovementV1",
            "OpenFind.awakeActivity.lockOnClosedDisplayV1",
            "OpenFind.awakeActivity.allowDisplaySleepWhenLockedV1",
        ]
        keys += [
            "OpenFind.awakeNotifications.automaticStartV1",
            "OpenFind.awakeNotifications.automaticEndV1",
            "OpenFind.awakeNotifications.remindersV1",
            "OpenFind.awakeNotifications.reminderMinutesV1",
            "OpenFind.awakeNotifications.notificationSoundV1",
            "OpenFind.awakeNotifications.startEndSoundV1",
            "OpenFind.awakeNotifications.replacementSoundV1",
            "OpenFind.awakeNotifications.cleanupV1",
            "OpenFind.awakeNotifications.closedDisplayWarningV1",
            "OpenFind.awakeNotifications.repeatClosedDisplayWarningV1",
            "OpenFind.awakeNotifications.closedDisplayWarningMinutesV1",
            "OpenFind.awakeNotifications.adjustClosedDisplayWarningVolumeV1",
            "OpenFind.awakeNotifications.closedDisplayWarningVolumeV1",
        ]
        return Set(keys)
    }()

    static func validate(_ values: [String: Any]) throws {
        try validatePortableValues(values)
        guard values.count <= all.count else { throw ConfigurationError.invalidPreferences }
        for value in values.values {
            if let string = value as? String, string.count > 100_000 { throw ConfigurationError.invalidPreferences }
            if let data = value as? Data, data.count > 32 * 1_024 * 1_024 { throw ConfigurationError.invalidPreferences }
            if let array = value as? [Any], array.count > 10_000 { throw ConfigurationError.invalidPreferences }
        }
    }
}

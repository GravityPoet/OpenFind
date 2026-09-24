import CoreFoundation
import Foundation

extension ConfigurationPreferenceKeys {
    static func validatePortableValues(_ values: [String: Any]) throws {
        let numericRanges: [String: ClosedRange<Double>] = [
            "search.maxContentFileSize": 0...Double(Int64.max / 2),
            "search.maxContentIndexBytes": 0...Double(Int64.max / 2),
            "OpenFind.driveAliveIntervalV1": 1...3_600,
            "OpenFind.keyboardLockAutoUnlockMinutesV1": 0...60,
            "OpenFind.keyboardLockPanelOpacityV1": KeyboardLockController.panelOpacityRange,
            "OpenFind.awakeDefaults.screenSaverDelayMinutesV1": 0...1_440,
            "OpenFind.awakeDefaults.durationMinutesV1": 0...10_080,
            "OpenFind.awakeAutomation.lowBatteryThresholdV1": 1...100,
            "OpenFind.awakeActivity.cursorIntervalSecondsV1": 5...3_600,
            "OpenFind.awakeActivity.cursorInactivitySecondsV1": 1...86_400,
            "OpenFind.awakeActivity.cursorStopAfterSecondsV1": 0...86_400,
            "OpenFind.awakeActivity.screenLockInactivitySecondsV1": 1...86_400,
            "OpenFind.awakeNotifications.reminderMinutesV1": 1...1_440,
            "OpenFind.awakeNotifications.closedDisplayWarningMinutesV1": 1...1_440,
            "OpenFind.awakeNotifications.closedDisplayWarningVolumeV1": 0...100,
        ]
        let enums: [String: Set<String>] = [
            "search.target": ["name", "content", "both"],
            "search.matchMode": ["substring", "wholeWord", "wildcard", "regex"],
            "OpenFind.interfaceSizeV1": ["compact", "standard", "large"],
            "OpenFind.quickSearchTriggerV1": ["shortcut", "doubleControl"],
            "OpenFind.awakeDefaults.endTimeCalculationV1": ["timer", "systemClock"],
            "OpenFind.awakeMenuBar.timeStyleV1": ["remaining", "endTime"],
            "OpenFind.awakeActivity.cursorSpeedV1": ["slow", "normal", "fast"],
        ]
        for (key, value) in values {
            if key == "OpenFind.clipboardPreferencesV3" {
                guard let data = value as? Data else { throw ConfigurationError.invalidPreferences }
                let decoded = try JSONDecoder().decode(ClipboardPreferences.self, from: data)
                guard decoded == decoded.normalized() else { throw ConfigurationError.invalidPreferences }
            } else if key == "OpenFind.awakeTriggersV1" {
                guard let data = value as? Data, data.count <= 2 * 1_024 * 1_024 else {
                    throw ConfigurationError.invalidPreferences
                }
                let triggers = try JSONDecoder().decode([AwakeTrigger].self, from: data)
                _ = try triggers.map { try $0.validated() }
                guard Set(triggers.map(\.id)).count == triggers.count,
                      Set(triggers.map { $0.name.lowercased() }).count == triggers.count else {
                    throw ConfigurationError.invalidPreferences
                }
            } else if key == QuickTerminalPrefix.persistenceKey {
                guard let prefix = value as? String, QuickTerminalPrefix.normalized(prefix) == prefix else {
                    throw ConfigurationError.invalidPreferences
                }
            } else if key == TerminalCommandTarget.persistenceKey {
                guard let target = value as? String, TerminalCommandTarget(rawValue: target) != nil else {
                    throw ConfigurationError.invalidPreferences
                }
            } else if let allowed = enums[key] {
                guard let string = value as? String, allowed.contains(string) else {
                    throw ConfigurationError.invalidPreferences
                }
            } else if key == "OpenFind.awakeDefaults.screenSaverExceptionsV1" {
                guard let identifiers = value as? [String], identifiers.count <= 1_000,
                      identifiers.allSatisfy({ !$0.isEmpty && $0.count <= 256 }) else {
                    throw ConfigurationError.invalidPreferences
                }
            } else if key.lowercased().contains("label") {
                guard let label = value as? String, !label.isEmpty, label.count <= 8,
                      !label.contains(where: \.isNewline) else { throw ConfigurationError.invalidPreferences }
            } else {
                guard let number = value as? NSNumber else { throw ConfigurationError.invalidPreferences }
                let isBool = CFGetTypeID(number) == CFBooleanGetTypeID()
                let range = numericRanges[key] ?? (key.lowercased().contains("keycode")
                    ? 0...Double(UInt16.max) : key.lowercased().contains("modifiers") ? 0...Double(UInt32.max) : nil)
                if let range {
                    guard !isBool, number.doubleValue.isFinite, range.contains(number.doubleValue),
                          key == "OpenFind.driveAliveIntervalV1" || key == "OpenFind.keyboardLockPanelOpacityV1"
                            || number.doubleValue.rounded() == number.doubleValue else {
                        throw ConfigurationError.invalidPreferences
                    }
                } else if !isBool {
                    throw ConfigurationError.invalidPreferences
                }
            }
        }
    }

    /// Device-local capture state and permissions do not travel. Canonical set
    /// ordering prevents equivalent preferences from ping-ponging between Macs.
    static func portableClipboardData(_ data: Data) throws -> Data {
        var preferences = try JSONDecoder().decode(ClipboardPreferences.self, from: data)
        preferences.capturePaused = false
        preferences.ignoreOnlyNextCapture = false
        preferences.popupScreen = 0
        let encoded = try JSONEncoder().encode(preferences)
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw ConfigurationError.invalidPreferences
        }
        for key in ["enabledStorageCategories", "ignoredBundleIdentifiers", "allowedBundleIdentifiers", "ignoredPasteboardTypes"] {
            if let items = object[key] as? [String] { object[key] = items.sorted() }
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

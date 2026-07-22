import Foundation

enum ClipboardPreferencesPersistence {
    private static let preferencesKey = "OpenFind.clipboardPreferencesV2"
    private static let historyLimitKey = "OpenFind.clipboardHistoryLimitV1"
    private static let itemLimitKey = "OpenFind.clipboardItemLimitBytesV1"
    private static let ignoredAppsKey = "OpenFind.clipboardIgnoredAppsV1"
    private static let pasteWithoutFormattingKey = "OpenFind.clipboardPasteWithoutFormattingV1"
    private static let clearHistoryOnQuitKey = "OpenFind.clipboardClearHistoryOnQuitV1"
    private static let clearSystemClipboardOnQuitKey = "OpenFind.clipboardClearSystemClipboardOnQuitV1"
    private static let fuzzySearchKey = "OpenFind.clipboardFuzzySearchV1"

    static func load(from defaults: UserDefaults) -> ClipboardPreferences {
        if let data = defaults.data(forKey: preferencesKey),
           let decoded = try? JSONDecoder().decode(ClipboardPreferences.self, from: data) {
            return decoded.normalized()
        }

        var preferences = ClipboardPreferences()
        if defaults.object(forKey: historyLimitKey) != nil {
            // A legacy numeric limit means this is an existing profile. Keep
            // its current clips intact until the user chooses a time period.
            preferences.retentionPeriod = .forever
        }
        if let value = defaults.object(forKey: itemLimitKey) as? Int {
            preferences.itemLimitBytes = value
        }
        preferences.ignoredBundleIdentifiers = Set(
            defaults.stringArray(forKey: ignoredAppsKey) ?? []
        )
        preferences.pasteWithoutFormatting = defaults.bool(forKey: pasteWithoutFormattingKey)
        preferences.clearHistoryOnQuit = defaults.bool(forKey: clearHistoryOnQuitKey)
        preferences.clearSystemClipboardOnQuit = defaults.bool(forKey: clearSystemClipboardOnQuitKey)
        if defaults.bool(forKey: fuzzySearchKey) {
            preferences.searchMode = .fuzzy
        }
        return preferences.normalized()
    }

    static func save(_ preferences: ClipboardPreferences, to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(preferences.normalized()) else { return }
        defaults.set(data, forKey: preferencesKey)
    }
}

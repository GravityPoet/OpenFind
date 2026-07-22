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
    private static let defaultIgnoredAppsSeedVersionKey =
        "OpenFind.clipboardDefaultIgnoredAppsSeedVersionV1"
    private static let currentDefaultIgnoredAppsSeedVersion = 1

    static func load(from defaults: UserDefaults) -> ClipboardPreferences {
        let preferences: ClipboardPreferences
        if let data = defaults.data(forKey: preferencesKey),
           let decoded = try? JSONDecoder().decode(ClipboardPreferences.self, from: data) {
            preferences = decoded.normalized()
        } else {
            var legacyPreferences = ClipboardPreferences()
            if defaults.object(forKey: historyLimitKey) != nil {
                // A legacy numeric limit means this is an existing profile. Keep
                // its current clips intact until the user chooses a time period.
                legacyPreferences.retentionPeriod = .forever
            }
            if let value = defaults.object(forKey: itemLimitKey) as? Int {
                legacyPreferences.itemLimitBytes = value
            }
            if defaults.object(forKey: ignoredAppsKey) != nil {
                legacyPreferences.ignoredBundleIdentifiers = Set(
                    defaults.stringArray(forKey: ignoredAppsKey) ?? []
                )
            }
            legacyPreferences.pasteWithoutFormatting = defaults.bool(
                forKey: pasteWithoutFormattingKey
            )
            legacyPreferences.clearHistoryOnQuit = defaults.bool(forKey: clearHistoryOnQuitKey)
            legacyPreferences.clearSystemClipboardOnQuit = defaults.bool(
                forKey: clearSystemClipboardOnQuitKey
            )
            if defaults.bool(forKey: fuzzySearchKey) {
                legacyPreferences.searchMode = .fuzzy
            }
            preferences = legacyPreferences.normalized()
        }
        return seedDefaultIgnoredApplicationsIfNeeded(preferences, in: defaults)
    }

    static func save(_ preferences: ClipboardPreferences, to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(preferences.normalized()) else { return }
        defaults.set(data, forKey: preferencesKey)
    }

    private static func seedDefaultIgnoredApplicationsIfNeeded(
        _ preferences: ClipboardPreferences,
        in defaults: UserDefaults
    ) -> ClipboardPreferences {
        guard defaults.integer(forKey: defaultIgnoredAppsSeedVersionKey)
                < currentDefaultIgnoredAppsSeedVersion else {
            return preferences
        }

        var seeded = preferences
        // In allow-list mode these identifiers would mean “allowed”, the opposite
        // of the privacy default, so leave that explicit user configuration intact.
        if !seeded.ignoreAllAppsExceptListed {
            seeded.ignoredBundleIdentifiers.formUnion(
                ClipboardPreferences.defaultIgnoredBundleIdentifiers
            )
        }
        seeded = seeded.normalized()
        guard let data = try? JSONEncoder().encode(seeded) else { return preferences }
        defaults.set(data, forKey: preferencesKey)
        defaults.set(currentDefaultIgnoredAppsSeedVersion, forKey: defaultIgnoredAppsSeedVersionKey)
        return seeded
    }
}

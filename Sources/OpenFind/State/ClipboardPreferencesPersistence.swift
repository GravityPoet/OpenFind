import Foundation

enum ClipboardPreferencesPersistence {
    private static let preferencesKey = "OpenFind.clipboardPreferencesV3"
    private static let legacyPreferencesKey = "OpenFind.clipboardPreferencesV2"
    private static let historyLimitKey = "OpenFind.clipboardHistoryLimitV1"
    private static let itemLimitKey = "OpenFind.clipboardItemLimitBytesV1"
    private static let ignoredAppsKey = "OpenFind.clipboardIgnoredAppsV1"
    private static let pasteWithoutFormattingKey = "OpenFind.clipboardPasteWithoutFormattingV1"
    private static let clearHistoryOnQuitKey = "OpenFind.clipboardClearHistoryOnQuitV1"
    private static let clearSystemClipboardOnQuitKey = "OpenFind.clipboardClearSystemClipboardOnQuitV1"
    private static let fuzzySearchKey = "OpenFind.clipboardFuzzySearchV1"
    private static let defaultIgnoredAppsSeedVersionKey =
        "OpenFind.clipboardDefaultIgnoredAppsSeedVersionV1"
    private static let currentDefaultIgnoredAppsSeedVersion = 2

    static func load(from defaults: UserDefaults) -> ClipboardPreferences {
        if let data = defaults.data(forKey: preferencesKey) {
            guard let decoded = try? JSONDecoder().decode(
                ClipboardPreferences.self,
                from: data
            ) else {
                // Never resurrect a stale V2 allow-list interpretation after a
                // damaged V3 payload. Recover from the primitive settings only.
                return finalizeLoad(
                    legacyPrimitivePreferences(from: defaults),
                    in: defaults,
                    forceSave: true
                )
            }
            return finalizeLoad(decoded.normalized(), in: defaults)
        }

        if let data = defaults.data(forKey: legacyPreferencesKey),
           let decoded = try? JSONDecoder().decode(ClipboardPreferences.self, from: data) {
            let migrated = safelyMigrateLegacyV2(decoded)
            let preferences = finalizeLoad(migrated, in: defaults, forceSave: true)
            return preferences
        }

        return finalizeLoad(
            legacyPrimitivePreferences(from: defaults),
            in: defaults,
            forceSave: true
        )
    }

    static func save(_ preferences: ClipboardPreferences, to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(preferences.normalized()) else { return }
        defaults.set(data, forKey: preferencesKey)
        writeRollbackSafeLegacySnapshot(preferences, to: defaults)
    }

    private static func finalizeLoad(
        _ preferences: ClipboardPreferences,
        in defaults: UserDefaults,
        forceSave: Bool = false
    ) -> ClipboardPreferences {
        let previousVersion = defaults.integer(forKey: defaultIgnoredAppsSeedVersionKey)
        var seeded = preferences
        if previousVersion < 1 {
            seeded.ignoredBundleIdentifiers.formUnion(
                ClipboardPreferences.defaultIgnoredBundleIdentifiersV1
            )
        }
        if previousVersion < 2 {
            // Seed only the new catalog delta. An application removed by the
            // user after an earlier seed must stay removed on later upgrades.
            seeded.ignoredBundleIdentifiers.formUnion(
                ClipboardPreferences.defaultIgnoredBundleIdentifiersV2
            )
        }
        seeded = seeded.normalized()
        if forceSave || previousVersion < currentDefaultIgnoredAppsSeedVersion {
            save(seeded, to: defaults)
        }
        if previousVersion < currentDefaultIgnoredAppsSeedVersion {
            defaults.set(
                currentDefaultIgnoredAppsSeedVersion,
                forKey: defaultIgnoredAppsSeedVersionKey
            )
        }
        return seeded
    }

    private static func safelyMigrateLegacyV2(
        _ preferences: ClipboardPreferences
    ) -> ClipboardPreferences {
        var migrated = preferences
        if migrated.captureOnlyFromAllowedApplications {
            // V2 reused the ignore list as an allow list. Its contents cannot be
            // trusted as consent for the new feature, so restore the deny list.
            migrated.ignoredBundleIdentifiers =
                ClipboardPreferences.defaultIgnoredBundleIdentifiers
        }
        migrated.allowedBundleIdentifiers = []
        migrated.captureOnlyFromAllowedApplications = false
        return migrated.normalized()
    }

    private static func writeRollbackSafeLegacySnapshot(
        _ preferences: ClipboardPreferences,
        to defaults: UserDefaults
    ) {
        var safeSnapshot = preferences
        safeSnapshot.allowedBundleIdentifiers = []
        safeSnapshot.captureOnlyFromAllowedApplications = false
        guard let data = try? JSONEncoder().encode(safeSnapshot.normalized()) else { return }
        // Older versions ignore the new fields and default their legacy mode to
        // off, preventing an app rollback from reviving the inverted list.
        defaults.set(data, forKey: legacyPreferencesKey)
    }

    private static func legacyPrimitivePreferences(
        from defaults: UserDefaults
    ) -> ClipboardPreferences {
        var preferences = ClipboardPreferences()
        if defaults.object(forKey: historyLimitKey) != nil {
            // A legacy numeric limit means this is an existing profile. Keep
            // its current clips intact until the user chooses a time period.
            preferences.retentionPeriod = .forever
        }
        if let value = defaults.object(forKey: itemLimitKey) as? Int {
            preferences.itemLimitBytes = value
        }
        if defaults.object(forKey: ignoredAppsKey) != nil {
            preferences.ignoredBundleIdentifiers = Set(
                defaults.stringArray(forKey: ignoredAppsKey) ?? []
            )
        } else {
            preferences.ignoredBundleIdentifiers =
                ClipboardPreferences.defaultIgnoredBundleIdentifiers
        }
        preferences.pasteWithoutFormatting = defaults.bool(
            forKey: pasteWithoutFormattingKey
        )
        preferences.clearHistoryOnQuit = defaults.bool(forKey: clearHistoryOnQuitKey)
        preferences.clearSystemClipboardOnQuit = defaults.bool(
            forKey: clearSystemClipboardOnQuitKey
        )
        if defaults.bool(forKey: fuzzySearchKey) {
            preferences.searchMode = .fuzzy
        }
        return preferences.normalized()
    }
}

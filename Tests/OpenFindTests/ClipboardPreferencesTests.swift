import AppKit
import Foundation
import Testing
@testable import OpenFind

@MainActor
@Suite("Clipboard Preferences Tests")
struct ClipboardPreferencesTests {
    @Test func applicationAllowListDefaultsToOffAndEmpty() {
        let preferences = ClipboardPreferences()

        #expect(preferences.allowedBundleIdentifiers.isEmpty)
        #expect(!preferences.captureOnlyFromAllowedApplications)
    }

    @Test func preferencePayloadIsNormalizedAndRoundTrips() throws {
        let suite = "OpenFindTests.ClipboardPreferencesV3.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var preferences = ClipboardPreferences()
        preferences.retentionPeriod = .days15
        preferences.itemLimitBytes = 1
        preferences.ignoredBundleIdentifiers = ["com.example.Editor", "bad\nvalue", ""]
        preferences.allowedBundleIdentifiers = ["com.example.Allowed", "bad\nvalue", ""]
        preferences.captureOnlyFromAllowedApplications = true
        preferences.ignoredTextPatterns = ["^secret$", "[", "^secret$"]
        preferences.clipboardCheckInterval = 30
        preferences.previewDelayMilliseconds = 1
        preferences.previewWidth = 2_000

        ClipboardPreferencesPersistence.save(preferences, to: defaults)
        let loaded = ClipboardPreferencesPersistence.load(from: defaults)

        #expect(loaded.retentionPeriod == .days15)
        #expect(loaded.itemLimitBytes == 1_024)
        #expect(loaded.ignoredBundleIdentifiers ==
            ClipboardPreferences.defaultIgnoredBundleIdentifiers.union(["com.example.Editor"]))
        #expect(loaded.allowedBundleIdentifiers == ["com.example.Allowed"])
        #expect(loaded.captureOnlyFromAllowedApplications)
        #expect(loaded.ignoredTextPatterns == ["^secret$"])
        #expect(loaded.clipboardCheckInterval == 5)
        #expect(loaded.previewDelayMilliseconds == 200)
        #expect(loaded.previewWidth == 800)
    }

    @Test func legacyPreferencesMigrateWithoutChangingUserChoices() throws {
        let suite = "OpenFindTests.ClipboardPreferencesLegacy.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(250, forKey: "OpenFind.clipboardHistoryLimitV1")
        defaults.set(4 * 1_024 * 1_024, forKey: "OpenFind.clipboardItemLimitBytesV1")
        defaults.set(["com.example.Legacy"], forKey: "OpenFind.clipboardIgnoredAppsV1")
        defaults.set(true, forKey: "OpenFind.clipboardPasteWithoutFormattingV1")
        defaults.set(true, forKey: "OpenFind.clipboardFuzzySearchV1")

        let loaded = ClipboardPreferencesPersistence.load(from: defaults)

        #expect(loaded.retentionPeriod == .forever)
        #expect(loaded.itemLimitBytes == 4 * 1_024 * 1_024)
        #expect(loaded.ignoredBundleIdentifiers ==
            ClipboardPreferences.defaultIgnoredBundleIdentifiers.union(["com.example.Legacy"]))
        #expect(loaded.pasteWithoutFormatting)
        #expect(loaded.searchMode == .fuzzy)
    }

    @Test func malformedCurrentPreferencesFallBackSafely() throws {
        let suite = "OpenFindTests.ClipboardPreferencesMalformed.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(
            Data(#"{"historyLimit":"not-a-number","searchMode":"unknown"}"#.utf8),
            forKey: "OpenFind.clipboardPreferencesV3"
        )
        defaults.set(
            try JSONSerialization.data(withJSONObject: [
                "ignoredBundleIdentifiers": ["com.example.AccidentalAllow"],
                "ignoreAllAppsExceptListed": true,
            ]),
            forKey: "OpenFind.clipboardPreferencesV2"
        )
        defaults.set(321, forKey: "OpenFind.clipboardHistoryLimitV1")

        let loaded = ClipboardPreferencesPersistence.load(from: defaults)

        #expect(loaded.retentionPeriod == .forever)
        #expect(loaded.searchMode == .exact)
        #expect(loaded.pinShortcut == ClipboardPreferences.defaultPinShortcut)
        #expect(loaded.ignoredBundleIdentifiers ==
            ClipboardPreferences.defaultIgnoredBundleIdentifiers)
        #expect(loaded.allowedBundleIdentifiers.isEmpty)
        #expect(!loaded.captureOnlyFromAllowedApplications)
    }

    @Test func passwordManagerDefaultsSeedOnceAndRespectRemoval() throws {
        let suite = "OpenFindTests.ClipboardDefaultIgnoredApps.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        var loaded = ClipboardPreferencesPersistence.load(from: defaults)
        #expect(loaded.ignoredBundleIdentifiers ==
            ClipboardPreferences.defaultIgnoredBundleIdentifiers)

        loaded.ignoredBundleIdentifiers.remove("com.bitwarden.desktop")
        ClipboardPreferencesPersistence.save(loaded, to: defaults)
        let reloaded = ClipboardPreferencesPersistence.load(from: defaults)

        #expect(!reloaded.ignoredBundleIdentifiers.contains("com.bitwarden.desktop"))
        #expect(reloaded.ignoredBundleIdentifiers.contains("com.1password.1password"))
        #expect(reloaded.ignoredBundleIdentifiers.contains("com.apple.Passwords"))
    }

    @Test func expandedPasswordManagerMigrationPreservesEarlierRemoval() throws {
        let suite = "OpenFindTests.ClipboardDefaultIgnoredAppsV2.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var preferences = ClipboardPreferences()
        preferences.ignoredBundleIdentifiers =
            ClipboardPreferences.defaultIgnoredBundleIdentifiersV1
                .subtracting(["com.bitwarden.desktop"])
        ClipboardPreferencesPersistence.save(preferences, to: defaults)
        defaults.set(1, forKey: "OpenFind.clipboardDefaultIgnoredAppsSeedVersionV1")

        let loaded = ClipboardPreferencesPersistence.load(from: defaults)

        #expect(!loaded.ignoredBundleIdentifiers.contains("com.bitwarden.desktop"))
        #expect(loaded.ignoredBundleIdentifiers.contains("org.keepassxc.keepassxc"))
        #expect(loaded.ignoredBundleIdentifiers.contains("in.sinew.Enpass-Desktop"))
        #expect(loaded.ignoredBundleIdentifiers.contains("com.apple.keychainaccess"))
        #expect(loaded.ignoredBundleIdentifiers ==
            ClipboardPreferences.defaultIgnoredBundleIdentifiers
                .subtracting(["com.bitwarden.desktop"]))
    }

    @Test func legacySharedAllowListMigratesToSafeIndependentDefaults() throws {
        let suite = "OpenFindTests.ClipboardSeparateAllowListMigration.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(
            try JSONSerialization.data(withJSONObject: [
                "ignoredBundleIdentifiers": [
                    "com.example.AccidentalAllow",
                    "com.bitwarden.desktop",
                ],
                "ignoreAllAppsExceptListed": true,
                "retentionPeriod": "days15",
            ]),
            forKey: "OpenFind.clipboardPreferencesV2"
        )
        defaults.set(2, forKey: "OpenFind.clipboardDefaultIgnoredAppsSeedVersionV1")

        let loaded = ClipboardPreferencesPersistence.load(from: defaults)

        #expect(loaded.retentionPeriod == .days15)
        #expect(!loaded.captureOnlyFromAllowedApplications)
        #expect(loaded.allowedBundleIdentifiers.isEmpty)
        #expect(loaded.ignoredBundleIdentifiers ==
            ClipboardPreferences.defaultIgnoredBundleIdentifiers)
        #expect(defaults.data(forKey: "OpenFind.clipboardPreferencesV3") != nil)

        let rollbackData = try #require(
            defaults.data(forKey: "OpenFind.clipboardPreferencesV2")
        )
        let rollbackPreferences = try JSONDecoder().decode(
            ClipboardPreferences.self,
            from: rollbackData
        )
        #expect(!rollbackPreferences.captureOnlyFromAllowedApplications)
        #expect(rollbackPreferences.allowedBundleIdentifiers.isEmpty)
    }

    @Test func legacyDenyListModePreservesExplicitUserRemovals() throws {
        let suite = "OpenFindTests.ClipboardDenyListMigration.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(
            try JSONSerialization.data(withJSONObject: [
                "ignoredBundleIdentifiers": ["com.example.CustomDenied"],
                "ignoreAllAppsExceptListed": false,
            ]),
            forKey: "OpenFind.clipboardPreferencesV2"
        )
        defaults.set(2, forKey: "OpenFind.clipboardDefaultIgnoredAppsSeedVersionV1")

        let loaded = ClipboardPreferencesPersistence.load(from: defaults)

        #expect(loaded.ignoredBundleIdentifiers == ["com.example.CustomDenied"])
        #expect(loaded.allowedBundleIdentifiers.isEmpty)
        #expect(!loaded.captureOnlyFromAllowedApplications)
    }

    @Test func defaultPasswordManagersAreRejectedBeforeStorage() throws {
        let context = try makeContext()
        let item = NSPasteboardItem()
        item.setString("sensitive", forType: .string)
        context.pasteboard.clearContents()
        #expect(context.pasteboard.writeObjects([item]))

        for identifier in ClipboardPreferences.defaultIgnoredBundleIdentifiers {
            #expect(!context.store.captureCurrentPasteboard(
                sourceBundleIdentifier: identifier
            ))
        }
        #expect(context.store.entries.isEmpty)
    }

    @Test func capturePoliciesCoverTypesPatternsAllowListsAndOneShotPause() throws {
        let context = try makeContext()
        let item = NSPasteboardItem()
        item.setString("ordinary", forType: .string)
        context.pasteboard.clearContents()
        #expect(context.pasteboard.writeObjects([item]))

        context.store.setStorageCategory(.text, enabled: false)
        #expect(!context.store.captureCurrentPasteboard())
        context.store.setStorageCategory(.text, enabled: true)

        context.store.setIgnoredTextPatterns(["^ordinary$"])
        #expect(!context.store.captureCurrentPasteboard())
        context.store.setIgnoredTextPatterns([])

        context.store.setAllowedBundleIdentifiers([])
        context.store.setCaptureOnlyFromAllowedApplications(true)
        #expect(!context.store.captureCurrentPasteboard(
            sourceBundleIdentifier: "com.example.Allowed"
        ))

        context.store.setIgnoredBundleIdentifiers(["com.example.Denied"])
        context.store.setAllowedBundleIdentifiers([
            "com.example.Allowed",
            "com.example.Denied",
        ])
        #expect(!context.store.captureCurrentPasteboard(
            sourceBundleIdentifier: "com.example.Blocked"
        ))
        #expect(!context.store.captureCurrentPasteboard())
        #expect(!context.store.captureCurrentPasteboard(
            sourceBundleIdentifier: "com.example.Blocked",
            sourceIdentifiers: ["com.example.Allowed"]
        ))
        #expect(!context.store.captureCurrentPasteboard(
            sourceBundleIdentifier: "com.example.Denied"
        ))
        #expect(!context.store.captureCurrentPasteboard(
            sourceBundleIdentifier: "com.example.Allowed",
            sourceIdentifiers: ["com.example.Denied"]
        ))
        #expect(context.store.captureCurrentPasteboard(
            sourceBundleIdentifier: "com.example.Allowed"
        ))

        context.store.clearAll()
        context.store.setCapturePaused(true)
        #expect(!context.store.captureCurrentPasteboard())
        context.store.setCapturePaused(false)
        context.store.setCaptureOnlyFromAllowedApplications(false)
        context.store.setAllowedBundleIdentifiers([])
        context.store.setIgnoredBundleIdentifiers([])
        context.store.ignoreNextCapture()
        #expect(!context.store.captureCurrentPasteboard())
        #expect(!context.store.preferences.capturePaused)
        #expect(!context.store.preferences.ignoreOnlyNextCapture)
        #expect(context.store.captureCurrentPasteboard())
    }

    @Test func customPasteboardTypesAreRejectedBeforeStorage() throws {
        let context = try makeContext()
        context.store.setIgnoredPasteboardTypes(["com.example.sensitive"])
        let item = NSPasteboardItem()
        item.setString("secret", forType: .string)
        item.setData(Data([1]), forType: .init("com.example.sensitive"))
        context.pasteboard.clearContents()
        #expect(context.pasteboard.writeObjects([item]))

        #expect(!context.store.captureCurrentPasteboard())
        #expect(context.store.entries.isEmpty)
    }

    @Test func searchAndSortModesMatchTheMaccyFallbackOrder() throws {
        let context = try makeContext()
        #expect(context.store.ingest(
            representations: ["public.utf8-plain-text": Data("Alpha".utf8)],
            previewText: "Alpha",
            kind: .text,
            createdAt: Date(timeIntervalSince1970: 1)
        ))
        #expect(context.store.ingest(
            representations: ["public.utf8-plain-text": Data("Beta".utf8)],
            previewText: "Beta",
            kind: .text,
            createdAt: Date(timeIntervalSince1970: 50)
        ))
        #expect(context.store.ingest(
            representations: ["public.utf8-plain-text": Data("Alpha".utf8)],
            previewText: "Alpha",
            kind: .text,
            createdAt: Date(timeIntervalSince1970: 100)
        ))

        context.store.setSortMode(.firstCopied)
        #expect(context.store.filteredEntries.first?.previewText == "Beta")
        context.store.setSearchMode(.regularExpression)
        context.store.query = "^B.ta$"
        #expect(context.store.filteredEntries.map(\.previewText) == ["Beta"])
        context.store.query = "["
        #expect(context.store.filteredEntries.isEmpty)
        context.store.setSearchMode(.mixed)
        context.store.query = "Bta"
        #expect(context.store.filteredEntries.map(\.previewText) == ["Beta"])
    }

    private func makeContext() throws -> ClipboardTestContext {
        let suite = "OpenFindTests.ClipboardPreferencesContext.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let pasteboard = NSPasteboard(name: .init("OpenFindTests.\(UUID())"))
        return ClipboardTestContext(
            store: ClipboardHistoryStore(
                defaults: defaults,
                persistence: PreferenceMemoryClipboardPersistence(),
                pasteboard: pasteboard
            ),
            pasteboard: pasteboard
        )
    }
}

private struct ClipboardTestContext {
    let store: ClipboardHistoryStore
    let pasteboard: NSPasteboard
}

private final class PreferenceMemoryClipboardPersistence: ClipboardHistoryPersisting {
    var requiresExplicitMigration = false
    private var entries: [ClipboardEntry] = []

    func load() throws -> [ClipboardEntry] { entries }
    func save(_ entries: [ClipboardEntry]) throws { self.entries = entries }
    func remove() throws { entries = [] }
}

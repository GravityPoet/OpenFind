import AppKit
import Foundation
import Testing
@testable import OpenFind

@MainActor
@Suite("Clipboard Quick Merge Tests")
struct ClipboardQuickMergeTests {
    @Test func preferencesAreOptInAndSurviveRoundTrip() throws {
        var preferences = ClipboardPreferences()
        #expect(!preferences.quickMergeEnabled)
        #expect(preferences.quickMergeSeparator == .newline)

        preferences.quickMergeEnabled = true
        preferences.quickMergeSeparator = .custom
        preferences.quickMergeCustomSeparator = " | "
        let decoded = try JSONDecoder().decode(
            ClipboardPreferences.self,
            from: JSONEncoder().encode(preferences)
        )

        #expect(decoded.quickMergeEnabled)
        #expect(decoded.quickMergeSeparator == .custom)
        #expect(decoded.quickMergeCustomSeparator == " | ")
    }

    @Test(arguments: [
        ("first", "second", "\n", "first\nsecond"),
        ("first", "second", " ", "first second"),
        ("first", "second", "", "firstsecond"),
        ("first", "second", " · ", "first · second"),
    ])
    func requestMergesDeterministically(
        base: String,
        appended: String,
        separator: String,
        expected: String
    ) {
        let request = ClipboardQuickMergeRequest(
            base: base,
            appended: appended,
            separator: separator,
            sourceBundleIdentifier: nil,
            sourceApplicationName: nil
        )

        #expect(request.mergedText == expected)
    }

    @Test func performingMergeWritesOneInternalClipboardAndHistoryEntry() throws {
        let suite = "OpenFindTests.QuickMerge.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let pasteboard = NSPasteboard(name: .init("OpenFindTests.\(UUID())"))
        let store = ClipboardHistoryStore(
            defaults: defaults,
            persistence: QuickMergeMemoryPersistence(),
            pasteboard: pasteboard
        )
        let controller = ClipboardQuickMergeController(
            store: store,
            pasteboard: pasteboard
        )

        controller.perform(ClipboardQuickMergeRequest(
            base: "alpha",
            appended: "beta",
            separator: "\n",
            sourceBundleIdentifier: "com.example.editor",
            sourceApplicationName: "Editor"
        ))

        #expect(pasteboard.string(forType: .string) == "alpha\nbeta")
        #expect(pasteboard.string(forType: .init(ClipboardHistoryStore.internalPasteboardType)) != nil)
        #expect(store.entries.count == 1)
        #expect(store.entries.first?.previewText == "alpha\nbeta")
        #expect(store.entries.first?.sourceBundleIdentifier == "com.example.editor")
        #expect(store.entries.first?.sourceApplicationName == "Editor")
    }
}

private final class QuickMergeMemoryPersistence: ClipboardHistoryPersisting {
    private var entries: [ClipboardEntry] = []
    func load() throws -> [ClipboardEntry] { entries }
    func save(_ entries: [ClipboardEntry]) throws { self.entries = entries }
    func remove() throws { entries = [] }
}

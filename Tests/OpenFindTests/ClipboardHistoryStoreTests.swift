import AppKit
import Foundation
import Testing
@testable import OpenFind

@MainActor
@Suite("Clipboard History Store Tests")
struct ClipboardHistoryStoreTests {
    @Test func deduplicatesSearchesAndPreservesPinnedItems() throws {
        let persistence = MemoryClipboardPersistence()
        let store = ClipboardHistoryStore(
            defaults: try #require(UserDefaults(suiteName: "OpenFindTests.Clipboard.\(UUID())")),
            persistence: persistence,
            pasteboard: NSPasteboard(name: .init("OpenFindTests.\(UUID())"))
        )
        let first = Data("first".utf8)
        let second = Data("second".utf8)
        #expect(store.ingest(
            representations: ["public.utf8-plain-text": first],
            previewText: "first value",
            kind: .text,
            createdAt: Date(timeIntervalSince1970: 1)
        ))
        #expect(store.ingest(
            representations: ["public.utf8-plain-text": second],
            previewText: "second value",
            kind: .text,
            createdAt: Date(timeIntervalSince1970: 2)
        ))
        let firstEntry = try #require(store.entries.first(where: { $0.previewText == "first value" }))
        store.togglePinned(firstEntry)
        store.query = "first"
        #expect(store.filteredEntries.count == 1)
        #expect(store.filteredEntries.first?.isPinned == true)

        #expect(store.ingest(
            representations: ["public.utf8-plain-text": first],
            previewText: "first updated",
            kind: .text,
            createdAt: Date(timeIntervalSince1970: 3)
        ))
        #expect(store.entries.count == 2)
        #expect(store.entries.first?.previewText == "first updated")
        #expect(store.entries.first?.isPinned == true)
    }

    @Test func persistenceCanBeDisabledAndClearsStoredHistory() throws {
        let suite = "OpenFindTests.Clipboard.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let persistence = MemoryClipboardPersistence()
        let store = ClipboardHistoryStore(
            defaults: defaults,
            persistence: persistence,
            pasteboard: NSPasteboard(name: .init("OpenFindTests.\(UUID())"))
        )
        #expect(store.ingest(
            representations: ["public.utf8-plain-text": Data("secret".utf8)],
            previewText: "secret",
            kind: .text
        ))
        #expect(persistence.savedEntries.count == 1)

        store.setPersistenceEnabled(false)
        #expect(!store.isPersistenceEnabled)
        #expect(persistence.removeCount == 1)
    }

    @Test func oversizedItemsAreRejectedBeforePersistence() throws {
        let suite = "OpenFindTests.Clipboard.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let persistence = MemoryClipboardPersistence()
        let store = ClipboardHistoryStore(
            defaults: defaults,
            persistence: persistence,
            pasteboard: NSPasteboard(name: .init("OpenFindTests.\(UUID())"))
        )
        let data = Data(repeating: 0, count: ClipboardHistoryStore.maximumItemBytes + 1)

        #expect(!store.ingest(
            representations: ["public.data": data],
            previewText: "large",
            kind: .other
        ))
        #expect(store.entries.isEmpty)
        #expect(persistence.savedEntries.isEmpty)
    }

    @Test func concealedAndIgnoredApplicationChangesAreNeverCaptured() throws {
        let suite = "OpenFindTests.Clipboard.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let pasteboard = NSPasteboard(name: .init("OpenFindTests.\(UUID())"))
        let store = ClipboardHistoryStore(
            defaults: defaults,
            persistence: MemoryClipboardPersistence(),
            pasteboard: pasteboard
        )
        let concealed = NSPasteboardItem()
        concealed.setString("secret", forType: .string)
        concealed.setData(
            Data([1]),
            forType: .init("org.nspasteboard.ConcealedType")
        )
        pasteboard.clearContents()
        #expect(pasteboard.writeObjects([concealed]))
        #expect(!store.captureCurrentPasteboard(sourceBundleIdentifier: "com.example.Passwords"))
        #expect(store.entries.isEmpty)

        store.setIgnoredBundleIdentifiers(["com.example.Editor"])
        let ordinary = NSPasteboardItem()
        ordinary.setString("ordinary", forType: .string)
        pasteboard.clearContents()
        #expect(pasteboard.writeObjects([ordinary]))
        #expect(!store.captureCurrentPasteboard(sourceBundleIdentifier: "com.example.Editor"))
        #expect(store.entries.isEmpty)
    }

    @Test func configurableHistoryLimitTrimsOldestUnpinnedEntries() throws {
        let suite = "OpenFindTests.Clipboard.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ClipboardHistoryStore(
            defaults: defaults,
            persistence: MemoryClipboardPersistence(),
            pasteboard: NSPasteboard(name: .init("OpenFindTests.\(UUID())"))
        )
        store.setHistoryLimit(10)
        for index in 0..<12 {
            #expect(store.ingest(
                representations: ["public.utf8-plain-text": Data("\(index)".utf8)],
                previewText: "item \(index)",
                kind: .text,
                createdAt: Date(timeIntervalSince1970: TimeInterval(index))
            ))
        }

        #expect(store.entries.count == 10)
        #expect(store.entries.first?.previewText == "item 11")
        #expect(store.entries.last?.previewText == "item 2")
    }

    @Test func plainTextCopyDropsRichRepresentations() throws {
        let suite = "OpenFindTests.Clipboard.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let pasteboard = NSPasteboard(name: .init("OpenFindTests.\(UUID())"))
        let store = ClipboardHistoryStore(
            defaults: defaults,
            persistence: MemoryClipboardPersistence(),
            pasteboard: pasteboard
        )
        #expect(store.ingest(
            representations: [
                NSPasteboard.PasteboardType.string.rawValue: Data("hello".utf8),
                "public.rtf": Data("{\\rtf1 hello}".utf8),
            ],
            previewText: "hello",
            kind: .richText
        ))
        let entry = try #require(store.entries.first)

        try store.copy(entry, plainTextOnly: true)

        #expect(pasteboard.string(forType: .string) == "hello")
        #expect(pasteboard.data(forType: .init("public.rtf")) == nil)
    }

    @Test func loadedPinnedItemsAreStillBoundedByTheHardPayloadLimit() throws {
        let suite = "OpenFindTests.Clipboard.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let payload = Data(repeating: 7, count: ClipboardHistoryStore.maximumItemBytes)
        let loaded = (0..<4).map { index in
            ClipboardEntry(
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                previewText: "pinned \(index)",
                kind: .other,
                representations: ["public.data.\(index)": payload],
                isPinned: true
            )
        }
        let store = ClipboardHistoryStore(
            defaults: defaults,
            persistence: MemoryClipboardPersistence(savedEntries: loaded),
            pasteboard: NSPasteboard(name: .init("OpenFindTests.\(UUID())"))
        )

        let retainedBytes = store.entries.reduce(0) { total, entry in
            total + entry.representations.values.reduce(0) { $0 + $1.count }
        }
        #expect(store.entries.count == 3)
        #expect(retainedBytes == ClipboardHistoryStore.maximumHistoryBytes)
        #expect(store.entries.allSatisfy { $0.isPinned })
    }

    @Test func aFullPinnedHistoryRejectsNewContentInsteadOfReportingInvisibleSuccess() throws {
        let suite = "OpenFindTests.Clipboard.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let loaded = (0..<ClipboardHistoryStore.maximumEntries).map { index in
            ClipboardEntry(
                previewText: "pinned \(index)",
                kind: .text,
                representations: ["public.utf8-plain-text": Data("\(index)".utf8)],
                isPinned: true
            )
        }
        let store = ClipboardHistoryStore(
            defaults: defaults,
            persistence: MemoryClipboardPersistence(savedEntries: loaded),
            pasteboard: NSPasteboard(name: .init("OpenFindTests.\(UUID())"))
        )

        #expect(!store.ingest(
            representations: ["public.utf8-plain-text": Data("new".utf8)],
            previewText: "new",
            kind: .text
        ))
        #expect(store.entries.count == ClipboardHistoryStore.maximumEntries)
        #expect(store.entries.allSatisfy { $0.previewText != "new" })
        #expect(store.lastErrorMessage == ClipboardHistoryError.historyFull.localizedDescription)
    }

    @Test func clipboardBehaviorPreferencesPersistAcrossReload() throws {
        let suite = "OpenFindTests.ClipboardPreferences.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let persistence = MemoryClipboardPersistence()
        let pasteboard = NSPasteboard(name: .init("OpenFindTests.ClipboardPreferences.\(UUID())"))
        let store = ClipboardHistoryStore(
            defaults: defaults,
            persistence: persistence,
            pasteboard: pasteboard
        )

        store.setPasteAutomatically(false)
        store.setPasteWithoutFormatting(true)
        store.setClearHistoryOnQuit(true)
        store.setClearSystemClipboardOnQuit(true)
        store.setFuzzySearchEnabled(true)

        let reloaded = ClipboardHistoryStore(
            defaults: defaults,
            persistence: persistence,
            pasteboard: pasteboard
        )
        #expect(!reloaded.pasteAutomatically)
        #expect(reloaded.pasteWithoutFormatting)
        #expect(reloaded.clearHistoryOnQuit)
        #expect(reloaded.clearSystemClipboardOnQuit)
        #expect(reloaded.fuzzySearchEnabled)
    }

    @Test func fuzzySearchRanksConsecutiveMatchesAndAcceptsApplicationAliases() throws {
        let suite = "OpenFindTests.ClipboardFuzzy.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let pasteboard = NSPasteboard(name: .init("OpenFindTests.ClipboardFuzzy.\(UUID())"))
        let store = ClipboardHistoryStore(
            defaults: defaults,
            persistence: MemoryClipboardPersistence(),
            pasteboard: pasteboard
        )
        store.setFuzzySearchEnabled(true)
        #expect(store.ingest(
            representations: ["public.utf8-plain-text": Data("OpenFind".utf8)],
            previewText: "OpenFind",
            kind: .text
        ))
        #expect(store.ingest(
            representations: ["public.utf8-plain-text": Data("Open file item".utf8)],
            previewText: "Open file item",
            kind: .text
        ))
        store.query = "ofd"
        #expect(store.filteredEntries.first?.previewText == "OpenFind")

        store.setIgnoredBundleIdentifiers(["Editor"])
        let item = NSPasteboardItem()
        item.setString("ignored", forType: .string)
        pasteboard.clearContents()
        #expect(pasteboard.writeObjects([item]))
        #expect(!store.captureCurrentPasteboard(
            sourceIdentifiers: ["Editor"]
        ))
    }

    @Test func quitPolicyClearsConfiguredHistoryAndSystemClipboard() throws {
        let suite = "OpenFindTests.ClipboardQuit.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let pasteboard = NSPasteboard(name: .init("OpenFindTests.ClipboardQuit.\(UUID())"))
        let persistence = MemoryClipboardPersistence()
        let store = ClipboardHistoryStore(
            defaults: defaults,
            persistence: persistence,
            pasteboard: pasteboard
        )
        store.setClearHistoryOnQuit(true)
        store.setClearSystemClipboardOnQuit(true)
        #expect(store.ingest(
            representations: ["public.utf8-plain-text": Data("temporary".utf8)],
            previewText: "temporary",
            kind: .text
        ))
        pasteboard.setString("temporary", forType: .string)

        store.prepareForTermination()

        #expect(store.entries.isEmpty)
        #expect(pasteboard.string(forType: .string) == nil)
    }
}

private final class MemoryClipboardPersistence: ClipboardHistoryPersisting {
    private(set) var savedEntries: [ClipboardEntry]
    private(set) var removeCount = 0

    init(savedEntries: [ClipboardEntry] = []) {
        self.savedEntries = savedEntries
    }

    func load() throws -> [ClipboardEntry] { savedEntries }
    func save(_ entries: [ClipboardEntry]) throws { savedEntries = entries }
    func remove() throws {
        savedEntries = []
        removeCount += 1
    }
}

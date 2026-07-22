import AppKit
import Foundation
import Testing
@testable import OpenFind

@MainActor
@Suite("Clipboard Parity Model Tests")
struct ClipboardParityModelTests {
    @Test func multipleFileItemsRoundTripWithoutSelfCapture() throws {
        let context = try makeContext()
        let firstURL = URL(fileURLWithPath: "/tmp/first.txt")
        let secondURL = URL(fileURLWithPath: "/tmp/second.txt")
        let firstItem = NSPasteboardItem()
        firstItem.setData(firstURL.dataRepresentation, forType: .fileURL)
        let secondItem = NSPasteboardItem()
        secondItem.setData(secondURL.dataRepresentation, forType: .fileURL)
        context.pasteboard.clearContents()
        #expect(context.pasteboard.writeObjects([firstItem, secondItem]))

        #expect(context.store.captureCurrentPasteboard())
        let entry = try #require(context.store.entries.first)
        #expect(entry.kind == .file)
        #expect(entry.retainedPasteboardItems.count == 2)
        #expect(entry.previewText.contains("first.txt"))
        #expect(entry.previewText.contains("second.txt"))

        try context.store.copy(entry)
        #expect(context.pasteboard.pasteboardItems?.count == 2)
        #expect(!context.store.captureCurrentPasteboard())
        #expect(context.store.entries.first?.numberOfCopies == 1)
    }

    @Test func pinnedEntriesReceiveUniqueStableKeysAndEditableAliases() throws {
        let context = try makeContext()
        for text in ["first", "second"] {
            #expect(context.store.ingest(
                representations: ["public.utf8-plain-text": Data(text.utf8)],
                previewText: text,
                kind: .text
            ))
        }
        let first = try #require(context.store.entries.first(where: { $0.previewText == "first" }))
        let second = try #require(context.store.entries.first(where: { $0.previewText == "second" }))
        context.store.togglePinned(first)
        context.store.togglePinned(second)
        let firstPinned = try #require(context.store.entries.first(where: { $0.id == first.id }))
        let secondPinned = try #require(context.store.entries.first(where: { $0.id == second.id }))
        #expect(firstPinned.pinKey != nil)
        #expect(secondPinned.pinKey != nil)
        #expect(firstPinned.pinKey != secondPinned.pinKey)

        context.store.setCustomTitle("Reusable greeting", for: firstPinned)
        #expect(context.store.setPlainText("edited value", for: firstPinned))
        let edited = try #require(context.store.entries.first(where: { $0.id == first.id }))
        #expect(edited.displayTitle == "Reusable greeting")
        #expect(edited.previewText == "edited value")
        #expect(edited.pinKey == firstPinned.pinKey)
    }

    @Test func disabledFileStorageStillRetainsAllowedTextFallback() throws {
        let context = try makeContext()
        context.store.setStorageCategory(.files, enabled: false)
        let item = NSPasteboardItem()
        item.setData(
            URL(fileURLWithPath: "/tmp/report.txt").dataRepresentation,
            forType: .fileURL
        )
        item.setString("report text", forType: .string)
        context.pasteboard.clearContents()
        #expect(context.pasteboard.writeObjects([item]))

        #expect(context.store.captureCurrentPasteboard())
        #expect(context.store.entries.first?.kind == .text)
        #expect(context.store.entries.first?.previewText == "report text")
        #expect(context.store.entries.first?.representations["public.file-url"] == nil)
    }

    @Test func multipleNonFilePasteboardItemsMergeIntoOneRetainedItem() throws {
        let context = try makeContext()
        let first = NSPasteboardItem()
        first.setString("plain", forType: .string)
        let second = NSPasteboardItem()
        second.setData(Data("{\\rtf1 rich}".utf8), forType: .rtf)

        let content = try #require(context.store.retainedContent(from: [first, second]))

        #expect(content.pasteboardItems == nil)
        #expect(content.representations[NSPasteboard.PasteboardType.string.rawValue] != nil)
        #expect(content.representations[NSPasteboard.PasteboardType.rtf.rawValue] != nil)
    }

    @Test func oldPreferencePayloadAdoptsActionShortcutDefaults() throws {
        struct OldPreferences: Encodable {
            let historyLimit = 200
            let searchMode = ClipboardSearchMode.fuzzy
        }
        let data = try JSONEncoder().encode(OldPreferences())
        let decoded = try JSONDecoder().decode(ClipboardPreferences.self, from: data)

        #expect(decoded.retentionPeriod == .forever)
        #expect(decoded.searchMode == .fuzzy)
        #expect(decoded.pinShortcut == ClipboardPreferences.defaultPinShortcut)
        #expect(decoded.deleteShortcut == ClipboardPreferences.defaultDeleteShortcut)
        #expect(decoded.previewShortcut == ClipboardPreferences.defaultPreviewShortcut)
    }

    @Test func searchRangesAndSpecialSymbolsMatchVisibleContent() throws {
        let candidate = "Alpha alpha ALPHA"
        let exact = try #require(ClipboardSearchEngine.match(
            query: "alpha",
            in: candidate,
            mode: .exact
        ))
        #expect(exact.ranges.map { String(candidate[$0]) } == ["Alpha", "alpha", "ALPHA"])
        #expect(ClipboardSearchEngine.match(
            query: "[",
            in: candidate,
            mode: .regularExpression
        ) == nil)
        let regex = try #require(ClipboardSearchEngine.match(
            query: "A[a-z]+",
            in: candidate,
            mode: .regularExpression
        ))
        #expect(regex.ranges.map { String(candidate[$0]) } == ["Alpha"])
        #expect(ClipboardHighlightedText.visibleTitle(
            "  first\tline\nsecond  ",
            showSpecialSymbols: true
        ) == "··first⇥line⏎second··")
        #expect(ClipboardHighlightedText.visibleTitle(
            "  first\tline\nsecond  ",
            showSpecialSymbols: false
        ) == "first\tline second")
    }

    @Test func previewVisibilityIsResetForEveryPresentation() throws {
        let context = try makeContext()

        context.store.beginPresentation()
        #expect(context.store.isPanelPresented)
        #expect(!context.store.isPreviewVisible)
        let firstGeneration = context.store.presentationGeneration
        context.store.isPreviewVisible = true

        context.store.endPresentation()
        #expect(!context.store.isPanelPresented)
        #expect(!context.store.isPreviewVisible)
        #expect(context.store.presentationGeneration == firstGeneration + 1)

        context.store.beginPresentation()
        #expect(context.store.isPanelPresented)
        #expect(!context.store.isPreviewVisible)
    }

    private func makeContext() throws -> ClipboardParityTestContext {
        let suite = "OpenFindTests.ClipboardParity.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let pasteboard = NSPasteboard(name: .init("OpenFindTests.\(UUID())"))
        return ClipboardParityTestContext(
            store: ClipboardHistoryStore(
                defaults: defaults,
                persistence: ParityMemoryClipboardPersistence(),
                pasteboard: pasteboard
            ),
            pasteboard: pasteboard
        )
    }
}

private struct ClipboardParityTestContext {
    let store: ClipboardHistoryStore
    let pasteboard: NSPasteboard
}

private final class ParityMemoryClipboardPersistence: ClipboardHistoryPersisting {
    var requiresExplicitMigration = false
    private var entries: [ClipboardEntry] = []

    func load() throws -> [ClipboardEntry] { entries }
    func save(_ entries: [ClipboardEntry]) throws { self.entries = entries }
    func remove() throws { entries = [] }
}

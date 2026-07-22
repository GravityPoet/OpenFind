import AppKit
import Foundation
import Testing
@testable import OpenFind

@MainActor
@Suite("Clipboard Paste Stack Tests")
struct ClipboardPasteStackTests {
    @Test func pointerStyleSelectionPreservesExistingMultiSelection() throws {
        let context = try makeContext()
        for text in ["first", "second"] {
            #expect(context.store.ingest(
                representations: ["public.utf8-plain-text": Data(text.utf8)],
                previewText: text,
                kind: .text
            ))
        }
        let first = try #require(context.store.entries.first(where: {
            $0.previewText == "first"
        }))
        let second = try #require(context.store.entries.first(where: {
            $0.previewText == "second"
        }))

        context.store.toggleMultiSelection(first)
        context.store.select(second, preservingMultiSelection: true)
        context.store.toggleMultiSelection(second)

        #expect(context.store.selectedEntryIDs == [first.id, second.id])
    }

    @Test func commandSelectionOrderDrivesSequentialClipboardValues() throws {
        let context = try makeContext()
        try ingestValues(["first", "second", "third"], into: context.store)
        let third = try #require(context.store.entries.first(where: { $0.previewText == "third" }))
        let first = try #require(context.store.entries.first(where: { $0.previewText == "first" }))
        let second = try #require(context.store.entries.first(where: { $0.previewText == "second" }))
        context.store.toggleMultiSelection(third)
        context.store.toggleMultiSelection(first)
        context.store.toggleMultiSelection(second)

        #expect(try context.store.startPasteStack() == third)
        #expect(context.pasteboard.string(forType: .string) == "third")
        #expect(context.store.multiSelectionCount == 0)
        #expect(try context.store.advancePasteStack())
        #expect(context.pasteboard.string(forType: .string) == "first")
        #expect(try context.store.advancePasteStack())
        #expect(context.pasteboard.string(forType: .string) == "second")
        #expect(try context.store.advancePasteStack() == false)
        #expect(context.store.pasteStack == nil)
    }

    @Test func shiftRangePreservesAnchorToTargetOrder() throws {
        let context = try makeContext()
        try ingestValues(["first", "second", "third"], into: context.store)
        let first = try #require(context.store.entries.first(where: { $0.previewText == "first" }))
        let third = try #require(context.store.entries.first(where: { $0.previewText == "third" }))
        context.store.select(first)
        context.store.selectionAnchorID = first.id
        context.store.selectRange(to: third)

        #expect(context.store.selectedEntriesInOrder.map(\.previewText) == [
            "first", "second", "third",
        ])
    }

    @Test func externalCopyInterruptsActivePasteStack() throws {
        let context = try makeContext()
        try ingestValues(["first", "second"], into: context.store)
        context.store.entries.forEach { context.store.toggleMultiSelection($0) }
        #expect(try context.store.startPasteStack() != nil)
        #expect(context.store.pasteStack != nil)

        let external = NSPasteboardItem()
        external.setString("external", forType: .string)
        context.pasteboard.clearContents()
        #expect(context.pasteboard.writeObjects([external]))
        #expect(context.store.captureCurrentPasteboard())
        #expect(context.store.pasteStack == nil)
    }

    @Test func deletingMultiSelectionRemovesEveryChosenEntry() throws {
        let context = try makeContext()
        try ingestValues(["first", "second", "third"], into: context.store)
        context.store.toggleMultiSelection(context.store.entries[0])
        context.store.toggleMultiSelection(context.store.entries[2])

        context.store.deleteSelection()

        #expect(context.store.entries.map(\.previewText) == ["second"])
        #expect(context.store.multiSelectionCount == 0)
    }

    private func ingestValues(_ values: [String], into store: ClipboardHistoryStore) throws {
        for (index, value) in values.enumerated() {
            #expect(store.ingest(
                representations: ["public.utf8-plain-text": Data(value.utf8)],
                previewText: value,
                kind: .text,
                createdAt: Date(timeIntervalSince1970: TimeInterval(index + 1))
            ))
        }
    }

    private func makeContext() throws -> ClipboardPasteStackTestContext {
        let suite = "OpenFindTests.ClipboardPasteStack.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let pasteboard = NSPasteboard(name: .init("OpenFindTests.\(UUID())"))
        return ClipboardPasteStackTestContext(
            store: ClipboardHistoryStore(
                defaults: defaults,
                persistence: PasteStackMemoryPersistence(),
                pasteboard: pasteboard
            ),
            pasteboard: pasteboard
        )
    }
}

private struct ClipboardPasteStackTestContext {
    let store: ClipboardHistoryStore
    let pasteboard: NSPasteboard
}

private final class PasteStackMemoryPersistence: ClipboardHistoryPersisting {
    var requiresExplicitMigration = false
    func load() throws -> [ClipboardEntry] { [] }
    func save(_ entries: [ClipboardEntry]) throws {}
    func remove() throws {}
}

import AppKit
import Carbon
import Foundation
import Testing
@testable import OpenFind

@MainActor
@Suite("Clipboard Snippet Tests")
struct ClipboardSnippetTests {
    @Test func reusableItemsSupportCollectionsKeywordsSearchAndExpansionMatching() throws {
        let context = try makeContext()
        let snippet = try context.store.createSnippet(
            name: "Support signature",
            content: "Kind regards,\nOpenFind",
            keyword: ";sig",
            collection: "Support",
            expandsAutomatically: true
        )

        #expect(snippet.isPinned)
        #expect(snippet.expandsFromKeyword)
        #expect(context.store.snippetCollectionNames == ["Support"])
        #expect(context.store.snippetEntry(matchingSuffix: "please reply ;SIG")?.id == snippet.id)

        context.store.query = "support"
        #expect(context.store.filteredEntries.map(\.id) == [snippet.id])
        context.store.query = ";sig"
        #expect(context.store.filteredEntries.map(\.id) == [snippet.id])
    }

    @Test func rendererResolvesDynamicValuesOnceAndTracksCursorPlacement() {
        let date = Date(timeIntervalSince1970: 1_704_164_645)
        let fixedUUID = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!
        var clipboardReads = 0

        let rendered = ClipboardSnippetRenderer.render(
            "{date:yyyy-MM-dd} {time:HH:mm} {clipboard}/{clipboard} {uuid} A{cursor}BC",
            now: date,
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(secondsFromGMT: 0)!,
            clipboardText: {
                clipboardReads += 1
                return "clip"
            },
            uuid: { fixedUUID }
        )

        #expect(rendered.text == "2024-01-02 03:04 clip/clip 01234567-89ab-cdef-0123-456789abcdef ABC")
        #expect(rendered.cursorOffsetFromEnd == 2)
        #expect(clipboardReads == 1)
    }

    @Test func archiveRoundTripIsAtomicAndKeepsReusableMetadata() throws {
        let source = try makeContext()
        _ = try source.store.createSnippet(
            name: "Greeting",
            content: "Hello {date}",
            keyword: ";hello",
            collection: "Replies",
            expandsAutomatically: true
        )
        _ = try source.store.createSnippet(
            name: "Address",
            content: "Tokyo",
            collection: "Personal"
        )
        let archive = try source.store.exportSnippetArchive()

        let destination = try makeContext()
        #expect(try destination.store.importSnippetArchive(archive) == 2)
        #expect(destination.store.reusableEntries.count == 2)
        #expect(Set(destination.store.snippetCollectionNames) == ["Personal", "Replies"])
        let greeting = try #require(destination.store.reusableEntries.first {
            $0.snippetKeyword == ";hello"
        })
        #expect(greeting.expandsFromKeyword)
        #expect(destination.store.plainText(for: greeting) == "Hello {date}")

        let duplicate = ClipboardSnippetArchive(snippets: [
            ClipboardSnippetRecord(
                id: UUID(),
                name: "Duplicate",
                content: "No change",
                keyword: ";hello",
                collection: nil,
                expandsAutomatically: true
            ),
        ])
        let data = try JSONEncoder().encode(duplicate)
        let entriesBeforeFailure = destination.store.entries
        #expect(throws: ClipboardSnippetError.duplicateKeyword) {
            try destination.store.importSnippetArchive(data)
        }
        #expect(destination.store.entries == entriesBeforeFailure)
    }

    @Test func importingAnExistingSnippetPreservesStableHistoryMetadata() throws {
        let context = try makeContext()
        let original = try context.store.createSnippet(
            name: "Original",
            content: "Before",
            keyword: ";before",
            collection: "Original group"
        )
        let originalEntry = try #require(context.store.entries.first { $0.id == original.id })
        let replacement = ClipboardSnippetArchive(snippets: [
            ClipboardSnippetRecord(
                id: original.id,
                name: "Updated",
                content: "After",
                keyword: ";after",
                collection: "Updated group",
                expandsAutomatically: true
            ),
        ])

        #expect(try context.store.importSnippetArchive(JSONEncoder().encode(replacement)) == 1)
        let updated = try #require(context.store.entries.first { $0.id == original.id })
        #expect(updated.pinKey == originalEntry.pinKey)
        #expect(updated.createdAt == originalEntry.createdAt)
        #expect(updated.firstCopiedAt == originalEntry.firstCopiedAt)
        #expect(updated.copyCount == originalEntry.copyCount)
        #expect(updated.displayTitle == "Updated")
        #expect(context.store.plainText(for: updated) == "After")
        #expect(updated.expandsFromKeyword)
    }

    @Test func duplicateArchiveIdentifiersAreRejectedAtomically() throws {
        let context = try makeContext()
        let id = UUID()
        let archive = ClipboardSnippetArchive(snippets: [
            ClipboardSnippetRecord(
                id: id,
                name: "One",
                content: "One",
                keyword: nil,
                collection: nil,
                expandsAutomatically: false
            ),
            ClipboardSnippetRecord(
                id: id,
                name: "Two",
                content: "Two",
                keyword: nil,
                collection: nil,
                expandsAutomatically: false
            ),
        ])

        #expect(throws: ClipboardSnippetError.duplicateIdentifiers) {
            try context.store.importSnippetArchive(JSONEncoder().encode(archive))
        }
        #expect(context.store.entries.isEmpty)
    }

    @Test func disablingPinAlsoDisablesExpansionAndRemovesSnippetMetadata() throws {
        let context = try makeContext()
        let snippet = try context.store.createSnippet(
            name: "Temporary",
            content: "Value",
            keyword: ";tmp",
            collection: "Scratch",
            expandsAutomatically: true
        )

        context.store.togglePinned(snippet)

        let updated = try #require(context.store.entries.first { $0.id == snippet.id })
        #expect(!updated.isPinned)
        #expect(updated.snippetKeyword == nil)
        #expect(updated.snippetCollection == nil)
        #expect(updated.snippetExpansionEnabled == nil)
        #expect(context.store.snippetEntry(matchingSuffix: ";tmp") == nil)
    }

    @Test func typingBufferIsBoundedEphemeralAndApplicationScoped() {
        var buffer = ClipboardSnippetTypingBuffer(maximumLength: 5, timeout: 2)
        #expect(buffer.consume(
            characters: "abcdef",
            keyCode: 0,
            modifiers: [],
            processIdentifier: 10,
            timestamp: 1
        ) == "bcdef")
        #expect(buffer.consume(
            characters: nil,
            keyCode: UInt16(kVK_Delete),
            modifiers: [],
            processIdentifier: 10,
            timestamp: 1.5
        ) == "bcde")
        #expect(buffer.consume(
            characters: "x",
            keyCode: 0,
            modifiers: [],
            processIdentifier: 11,
            timestamp: 1.6
        ) == "x")
        #expect(buffer.consume(
            characters: "y",
            keyCode: 0,
            modifiers: .command,
            processIdentifier: 11,
            timestamp: 1.7
        ).isEmpty)
        #expect(buffer.consume(
            characters: "z",
            keyCode: 0,
            modifiers: [],
            processIdentifier: 11,
            timestamp: 5
        ) == "z")
    }

    @Test func usingConfiguredSnippetRendersPlaceholdersAndReturnsCursorOffset() throws {
        let context = try makeContext()
        let snippet = try context.store.createSnippet(
            name: "Template",
            content: "A{clipboard}B{cursor}CD",
            collection: "Templates"
        )
        context.store.pasteboard.setString("current", forType: .string)

        let offset = try context.store.copy(snippet)

        #expect(context.store.pasteboard.string(forType: .string) == "AcurrentBCD")
        #expect(offset == 2)
    }

    private func makeContext() throws -> SnippetTestContext {
        let suite = "OpenFindTests.Snippets.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return SnippetTestContext(
            store: ClipboardHistoryStore(
                defaults: defaults,
                persistence: SnippetMemoryPersistence(),
                pasteboard: NSPasteboard(name: .init("OpenFindTests.\(UUID())"))
            )
        )
    }
}

private struct SnippetTestContext {
    let store: ClipboardHistoryStore
}

private final class SnippetMemoryPersistence: ClipboardHistoryPersisting {
    private var entries: [ClipboardEntry] = []
    func load() throws -> [ClipboardEntry] { entries }
    func save(_ entries: [ClipboardEntry]) throws { self.entries = entries }
    func remove() throws { entries = [] }
}

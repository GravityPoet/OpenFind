import AppKit
import Foundation
import Testing
@testable import OpenFind

@MainActor
@Suite("Clipboard Payload Residency Tests", .serialized)
struct ClipboardPayloadResidencyTests {
    @Test func encryptedResidentIndexKeepsPayloadColdAndMetadataUpdatesPreserveBytes() throws {
        let context = try makeEncryptedContext()
        defer { context.cleanup() }
        let first = entry("first", extra: ["public.html": Data("<b>first</b>".utf8)])
        let second = entry("second")
        let writer = context.persistence()
        try writer.save([first, second])

        let reader = context.persistence()
        var summaries = try reader.loadResidentHistory()
        #expect(summaries.map(\.id) == [first.id, second.id])
        #expect(summaries.allSatisfy { !$0.hasResidentPayload })
        #expect(reader.unloadedPayloadEntryIDs == [first.id, second.id])
        #expect(summaries.map { $0.resolvedPayloadDescriptor?.byteCount } == [
            first.resolvedPayloadDescriptor?.byteCount,
            second.resolvedPayloadDescriptor?.byteCount,
        ])
        #expect(try reader.loadEntry(id: first.id)?.retainedPasteboardItems
            == first.retainedPasteboardItems)

        summaries[0].isPinned = true
        try reader.save(summaries, preservingPayloadsFor: Set(summaries.map(\.id)))

        let reloaded = try context.persistence().load()
        #expect(reloaded[0].isPinned)
        #expect(reloaded[0].retainedPasteboardItems == first.retainedPasteboardItems)
        #expect(reloaded[1].retainedPasteboardItems == second.retainedPasteboardItems)
    }

    @Test func backgroundHibernateReleasesPayloadButSearchCopyAndDedupStayAvailable() throws {
        let suite = "OpenFindTests.PayloadHibernate.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let persistence = ResidencyMemoryPersistence()
        let pasteboard = NSPasteboard(name: .init("OpenFindTests.\(UUID())"))
        let store = ClipboardHistoryStore(
            defaults: defaults,
            persistence: persistence,
            pasteboard: pasteboard
        )
        let payload = Data(repeating: 7, count: 2 * 1_024 * 1_024)
        #expect(store.ingest(
            representations: ["public.png": payload],
            previewText: "large image",
            kind: .image
        ))
        let id = try #require(store.entries.first?.id)

        store.hibernatePayloadsForBackground()

        #expect(store.residentPayloadBytes == 0)
        #expect(store.entries.first?.representations.isEmpty == true)
        store.query = "large image"
        #expect(store.filteredEntries.map(\.id) == [id])
        try store.copy(try #require(store.entries.first))
        #expect(pasteboard.data(forType: .png) == payload)

        #expect(store.ingest(
            representations: ["public.png": payload],
            previewText: "large image",
            kind: .image
        ))
        #expect(store.entries.count == 1)
        #expect(store.entries.first?.id == id)
        #expect(store.residentPayloadBytes == 0)
    }

    @Test func backgroundHibernateRetainsSmallHotPayloadAndDropsColdLargePayload() throws {
        let suite = "OpenFindTests.PayloadHotSet.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let persistence = ResidencyMemoryPersistence()
        let pasteboard = NSPasteboard(name: .init("OpenFindTests.\(UUID())"))
        let store = ClipboardHistoryStore(
            defaults: defaults,
            persistence: persistence,
            pasteboard: pasteboard
        )
        #expect(store.ingest(
            representations: ["public.utf8-plain-text": Data("frequent clip".utf8)],
            previewText: "frequent clip",
            kind: .text
        ))
        let hot = try #require(store.entries.first)
        #expect(store.saveForReuse(hot))

        let pinnedImagePayload = Data(repeating: 8, count: 2 * 1_024 * 1_024)
        #expect(store.ingest(
            representations: ["public.png": pinnedImagePayload],
            previewText: "pinned image",
            kind: .image
        ))
        let pinnedImage = try #require(store.entries.first)
        #expect(store.saveForReuse(pinnedImage))

        let coldPayload = Data(repeating: 9, count: 2 * 1_024 * 1_024)
        #expect(store.ingest(
            representations: ["public.png": coldPayload],
            previewText: "cold image",
            kind: .image
        ))
        let coldID = try #require(store.entries.first?.id)

        store.hibernatePayloadsForBackground()

        let retainedHot = try #require(store.entries.first { $0.id == hot.id })
        let retainedPinnedImage = try #require(
            store.entries.first { $0.id == pinnedImage.id }
        )
        let releasedCold = try #require(store.entries.first { $0.id == coldID })
        #expect(retainedHot.isPinned)
        #expect(retainedHot.hasResidentPayload)
        #expect(retainedPinnedImage.isPinned)
        #expect(retainedPinnedImage.hasResidentPayload)
        #expect(!releasedCold.hasResidentPayload)
        #expect(store.residentPayloadBytes > 0)
        #expect(
            store.residentPayloadBytes
                <= ClipboardHistoryStore.backgroundPayloadRetentionBudget
        )
    }

    @Test func automaticallyFrequentlyUsedPayloadStaysWarmForRepeatedCopy() throws {
        let suite = "OpenFindTests.PayloadFrequentHotSet.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let persistence = ResidencyMemoryPersistence()
        let pasteboard = NSPasteboard(name: .init("OpenFindTests.\(UUID())"))
        let store = ClipboardHistoryStore(
            defaults: defaults,
            persistence: persistence,
            pasteboard: pasteboard
        )
        #expect(store.ingest(
            representations: ["public.utf8-plain-text": Data("frequent text".utf8)],
            previewText: "frequent text",
            kind: .text
        ))
        let entry = try #require(store.entries.first)
        for _ in 0..<3 {
            try store.copy(entry)
        }
        #expect(store.entries.first?.numberOfUses == 3)

        store.hibernatePayloadsForBackground()
        let retained = try #require(store.entries.first)
        #expect(retained.hasResidentPayload)

        let loadsBeforeRepeatedCopy = persistence.loadEntryCount
        for _ in 0..<5 {
            try store.copy(retained)
        }
        #expect(persistence.loadEntryCount == loadsBeforeRepeatedCopy)
    }

    @Test func failedSaveKeepsNewPayloadResidentInsteadOfCreatingAnUnrecoverableSummary() throws {
        let suite = "OpenFindTests.PayloadSaveFailure.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ClipboardHistoryStore(
            defaults: defaults,
            persistence: FailingSaveResidencyPersistence(),
            pasteboard: NSPasteboard(name: .init("OpenFindTests.\(UUID())"))
        )
        #expect(store.ingest(
            representations: ["public.utf8-plain-text": Data("unsaved".utf8)],
            previewText: "unsaved",
            kind: .text
        ))

        store.hibernatePayloadsForBackground()

        #expect(store.entries.first?.hasResidentPayload == true)
        #expect(store.residentPayloadBytes > 0)
    }

    private func entry(_ text: String, extra: [String: Data] = [:]) -> ClipboardEntry {
        var representations = extra
        representations["public.utf8-plain-text"] = Data(text.utf8)
        return ClipboardEntry(
            previewText: text,
            kind: .text,
            representations: representations
        )
    }

    private func makeEncryptedContext() throws -> EncryptedResidencyContext {
        let suite = "OpenFindTests.PayloadIndex.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "OpenFind-PayloadIndex-\(UUID())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return EncryptedResidencyContext(
            defaults: defaults,
            suite: suite,
            directory: directory
        )
    }
}

private final class ResidencyMemoryPersistence: ClipboardHistoryPersisting {
    private var stored: [ClipboardEntry] = []
    private(set) var loadEntryCount = 0
    func load() throws -> [ClipboardEntry] { stored }
    func loadEntry(id: UUID) throws -> ClipboardEntry? {
        loadEntryCount += 1
        return stored.first { $0.id == id }
    }
    func save(_ entries: [ClipboardEntry]) throws { stored = entries }
    func remove() throws { stored = [] }
}

private final class FailingSaveResidencyPersistence: ClipboardHistoryPersisting {
    func load() throws -> [ClipboardEntry] { [] }
    func save(_ entries: [ClipboardEntry]) throws {
        throw ClipboardHistoryError.persistenceUnavailable
    }
    func remove() throws {}
}

private final class ResidencyKeychain: ClipboardHistoryKeychainAccessing {
    var data: Data?
    func read() throws -> Data? { data }
    func store(_ data: Data) throws { self.data = data }
    func remove() throws { data = nil }
}

private final class EncryptedResidencyContext {
    let defaults: UserDefaults
    let suite: String
    let directory: URL
    private let keychain = ResidencyKeychain()

    init(defaults: UserDefaults, suite: String, directory: URL) {
        self.defaults = defaults
        self.suite = suite
        self.directory = directory
    }

    func persistence() -> EncryptedClipboardHistoryPersistence {
        EncryptedClipboardHistoryPersistence(
            defaults: defaults,
            keyFileURL: directory.appendingPathComponent("key"),
            databaseURL: directory.appendingPathComponent("history.sqlite3"),
            keychain: keychain,
            signingTeamIdentifier: nil
        )
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

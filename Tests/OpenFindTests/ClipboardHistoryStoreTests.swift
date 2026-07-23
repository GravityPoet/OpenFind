import AppKit
import CryptoKit
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

    @Test func repeatedCopiesPreserveOriginMetadataAndRemainSearchable() throws {
        let suite = "OpenFindTests.ClipboardMetadata.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ClipboardHistoryStore(
            defaults: defaults,
            persistence: MemoryClipboardPersistence(),
            pasteboard: NSPasteboard(name: .init("OpenFindTests.\(UUID())"))
        )
        let content = Data("same value".utf8)
        let firstDate = Date(timeIntervalSince1970: 10)
        let lastDate = Date(timeIntervalSince1970: 20)

        #expect(store.ingest(
            representations: ["public.utf8-plain-text": content],
            previewText: "same value",
            kind: .text,
            createdAt: firstDate,
            sourceBundleIdentifier: "com.apple.TextEdit",
            sourceApplicationName: "TextEdit"
        ))
        #expect(store.ingest(
            representations: ["public.utf8-plain-text": content],
            previewText: "same value",
            kind: .text,
            createdAt: lastDate,
            sourceBundleIdentifier: "com.apple.Safari",
            sourceApplicationName: "Safari"
        ))

        let entry = try #require(store.entries.first)
        #expect(store.entries.count == 1)
        #expect(entry.initialCopiedAt == firstDate)
        #expect(entry.createdAt == lastDate)
        #expect(entry.numberOfCopies == 2)
        #expect(entry.sourceApplicationName == "Safari")
        store.query = "safari"
        #expect(store.filteredEntries.map(\.id) == [entry.id])
    }

    @Test func pinningKeepsTheSameEntrySelectedAfterItMoves() throws {
        let suite = "OpenFindTests.ClipboardSelection.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ClipboardHistoryStore(
            defaults: defaults,
            persistence: MemoryClipboardPersistence(),
            pasteboard: NSPasteboard(name: .init("OpenFindTests.\(UUID())"))
        )
        for index in 1...2 {
            #expect(store.ingest(
                representations: ["public.utf8-plain-text": Data("\(index)".utf8)],
                previewText: "item \(index)",
                kind: .text,
                createdAt: Date(timeIntervalSince1970: TimeInterval(index))
            ))
        }
        let olderEntry = try #require(store.entries.first(where: { $0.previewText == "item 1" }))
        store.select(olderEntry)
        #expect(store.selectedIndex == 1)

        store.togglePinned(olderEntry)

        #expect(store.selectedIndex == 0)
        #expect(store.selectedEntry?.id == olderEntry.id)
    }

    @Test func filesAndURLsAreClassifiedBeforeTheirPlainTextFallbacks() throws {
        let suite = "OpenFindTests.ClipboardClassification.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let pasteboard = NSPasteboard(name: .init("OpenFindTests.\(UUID())"))
        let store = ClipboardHistoryStore(
            defaults: defaults,
            persistence: MemoryClipboardPersistence(),
            pasteboard: pasteboard
        )

        let fileURL = URL(fileURLWithPath: "/tmp/example.txt")
        let fileItem = NSPasteboardItem()
        fileItem.setString("example.txt", forType: .string)
        fileItem.setData(fileURL.dataRepresentation, forType: .init("public.file-url"))
        pasteboard.clearContents()
        #expect(pasteboard.writeObjects([fileItem]))
        #expect(store.captureCurrentPasteboard())
        #expect(store.entries.first?.kind == .file)

        let webURL = try #require(URL(string: "https://openfind.example/path"))
        let urlItem = NSPasteboardItem()
        urlItem.setString(webURL.absoluteString, forType: .string)
        urlItem.setData(webURL.dataRepresentation, forType: .init("public.url"))
        pasteboard.clearContents()
        #expect(pasteboard.writeObjects([urlItem]))
        #expect(store.captureCurrentPasteboard())
        #expect(store.entries.first?.kind == .url)
    }

    @Test func legacyEntriesDecodeWithoutNewInteractionMetadata() throws {
        struct LegacyEntry: Encodable {
            let id: UUID
            let createdAt: Date
            let previewText: String
            let kind: ClipboardEntryKind
            let representations: [String: Data]
            let isPinned: Bool
        }
        let createdAt = Date(timeIntervalSince1970: 42)
        let encoded = try JSONEncoder().encode(LegacyEntry(
            id: UUID(),
            createdAt: createdAt,
            previewText: "legacy",
            kind: .text,
            representations: ["public.utf8-plain-text": Data("legacy".utf8)],
            isPinned: false
        ))

        let decoded = try JSONDecoder().decode(ClipboardEntry.self, from: encoded)

        #expect(decoded.initialCopiedAt == createdAt)
        #expect(decoded.numberOfCopies == 1)
        #expect(decoded.sourceApplicationName == nil)
        #expect(decoded.recognizedText == nil)
        #expect(decoded.imageTextRecognitionRevision == nil)
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

    @Test func legacyHistoryWaitsForExplicitMigrationWithoutBeingOverwritten() throws {
        let suite = "OpenFindTests.ClipboardMigrationStore.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let existing = ClipboardEntry(
            previewText: "preserved",
            kind: .text,
            representations: ["public.utf8-plain-text": Data("preserved".utf8)]
        )
        let persistence = MemoryClipboardPersistence(
            savedEntries: [existing],
            requiresExplicitMigration: true
        )

        let store = ClipboardHistoryStore(
            defaults: defaults,
            persistence: persistence,
            pasteboard: NSPasteboard(name: .init("OpenFindTests.\(UUID())"))
        )

        #expect(store.requiresPersistenceMigration)
        #expect(store.entries.isEmpty)
        #expect(persistence.loadCount == 0)
        #expect(!store.ingest(
            representations: ["public.utf8-plain-text": Data("new".utf8)],
            previewText: "new",
            kind: .text
        ))
        #expect(persistence.saveCount == 0)

        #expect(store.migratePersistence())
        #expect(!store.requiresPersistenceMigration)
        #expect(store.entries == [existing])
        #expect(persistence.loadCount == 1)
    }

    @Test func selfSignedPersistenceMigratesLegacyKeyOnlyOnce() throws {
        let suite = "OpenFindTests.ClipboardKeyMigration.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "OpenFindClipboardMigration-\(UUID())",
            isDirectory: true
        )
        let keyURL = directory.appendingPathComponent("clipboard-history-key-v3")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let keychain = MemoryClipboardKeychain()
        let existing = ClipboardEntry(
            previewText: "legacy",
            kind: .text,
            representations: ["public.utf8-plain-text": Data("legacy".utf8)]
        )
        try seedLegacyHistory([existing], defaults: defaults, keychain: keychain)
        #expect(!FileManager.default.fileExists(atPath: keyURL.path))

        let localReader = EncryptedClipboardHistoryPersistence(
            defaults: defaults,
            keyFileURL: keyURL,
            keychain: keychain,
            signingTeamIdentifier: nil
        )
        #expect(localReader.requiresExplicitMigration)
        let readsBeforeMigration = keychain.readCount

        #expect(try localReader.load() == [existing])
        #expect(!localReader.requiresExplicitMigration)
        #expect(keychain.readCount == readsBeforeMigration + 1)
        let attributes = try FileManager.default.attributesOfItem(atPath: keyURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        let readsAfterMigration = keychain.readCount
        #expect(try localReader.load() == [existing])
        #expect(keychain.readCount == readsAfterMigration)
    }

    @Test func newSelfSignedHistoryCreatesAFileKeyWithoutOpeningKeychain() throws {
        let suite = "OpenFindTests.ClipboardLocalKey.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "OpenFindClipboardLocalKey-\(UUID())",
            isDirectory: true
        )
        let keyURL = directory.appendingPathComponent("clipboard-history-key-v3")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let keychain = MemoryClipboardKeychain()
        let persistence = EncryptedClipboardHistoryPersistence(
            defaults: defaults,
            keyFileURL: keyURL,
            keychain: keychain,
            signingTeamIdentifier: nil
        )
        let entry = ClipboardEntry(
            previewText: "new",
            kind: .text,
            representations: ["public.utf8-plain-text": Data("new".utf8)]
        )

        try persistence.save([entry])

        #expect(keychain.readCount == 0)
        #expect(keychain.storeCount == 0)
        #expect(try persistence.load() == [entry])
        #expect(FileManager.default.fileExists(atPath: keyURL.path))
    }

    @Test func encryptedDatabaseRoundTripsFiveThousandItemsAndOneEntryUpdate() throws {
        let suite = "OpenFindTests.ClipboardDatabase.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "OpenFindClipboardDatabase-\(UUID())",
            isDirectory: true
        )
        let keyURL = directory.appendingPathComponent("clipboard-history-key-v3")
        let databaseURL = directory.appendingPathComponent("clipboard-history-v3.sqlite3")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let entries = (0..<5_000).map { index in
            let value = "persisted item \(index)"
            return ClipboardEntry(
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                previewText: value,
                kind: .text,
                representations: ["public.utf8-plain-text": Data(value.utf8)],
                isPinned: index.isMultiple(of: 997)
            )
        }
        let writer = EncryptedClipboardHistoryPersistence(
            defaults: defaults,
            keyFileURL: keyURL,
            databaseURL: databaseURL,
            keychain: MemoryClipboardKeychain(),
            signingTeamIdentifier: nil
        )

        let initialStart = ContinuousClock.now
        try writer.save(entries)
        let initialDuration = initialStart.duration(to: .now)

        let reader = EncryptedClipboardHistoryPersistence(
            defaults: defaults,
            keyFileURL: keyURL,
            databaseURL: databaseURL,
            keychain: MemoryClipboardKeychain(),
            signingTeamIdentifier: nil
        )
        #expect(try reader.load() == entries)
        var updated = entries
        updated[2_500].previewText = "updated once"

        let updateStart = ContinuousClock.now
        try reader.save(updated)
        let updateDuration = updateStart.duration(to: .now)

        let verifier = EncryptedClipboardHistoryPersistence(
            defaults: defaults,
            keyFileURL: keyURL,
            databaseURL: databaseURL,
            keychain: MemoryClipboardKeychain(),
            signingTeamIdentifier: nil
        )
        #expect(try verifier.load() == updated)
        #expect(defaults.data(forKey: EncryptedClipboardHistoryPersistence.ciphertextKey) == nil)
        let attributes = try FileManager.default.attributesOfItem(atPath: databaseURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(initialDuration < .seconds(5))
        #expect(updateDuration < .seconds(2))
    }

    @Test func localKeySymlinkIsRejectedWithoutTouchingItsTarget() throws {
        let suite = "OpenFindTests.ClipboardKeySymlink.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "OpenFindClipboardKeySymlink-\(UUID())",
            isDirectory: true
        )
        let targetURL = directory.appendingPathComponent("unrelated")
        let keyURL = directory.appendingPathComponent("clipboard-history-key-v3")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let unrelated = Data(repeating: 7, count: 32)
        try unrelated.write(to: targetURL)
        try FileManager.default.createSymbolicLink(at: keyURL, withDestinationURL: targetURL)
        let persistence = EncryptedClipboardHistoryPersistence(
            defaults: defaults,
            keyFileURL: keyURL,
            keychain: MemoryClipboardKeychain(),
            signingTeamIdentifier: nil
        )

        #expect(throws: ClipboardHistoryError.persistenceUnavailable) {
            try persistence.save([])
        }
        #expect(try Data(contentsOf: targetURL) == unrelated)
    }

    @Test func corruptLegacyCiphertextNeverCommitsTheMigratedKey() throws {
        let suite = "OpenFindTests.ClipboardCorruptMigration.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "OpenFindClipboardCorruptMigration-\(UUID())",
            isDirectory: true
        )
        let keyURL = directory.appendingPathComponent("clipboard-history-key-v3")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let keychain = MemoryClipboardKeychain()
        keychain.data = Data(repeating: 23, count: 32)
        defaults.set(Data(repeating: 0, count: 64), forKey: EncryptedClipboardHistoryPersistence.ciphertextKey)
        let localReader = EncryptedClipboardHistoryPersistence(
            defaults: defaults,
            keyFileURL: keyURL,
            keychain: keychain,
            signingTeamIdentifier: nil
        )

        #expect(throws: ClipboardHistoryError.persistenceCorrupt) {
            try localReader.load()
        }
        #expect(!FileManager.default.fileExists(atPath: keyURL.path))
        #expect(localReader.requiresExplicitMigration)
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

    @Test func retentionPeriodExpiresOldUnpinnedEntriesAndPreservesPinnedItems() throws {
        let suite = "OpenFindTests.Clipboard.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ClipboardHistoryStore(
            defaults: defaults,
            persistence: MemoryClipboardPersistence(),
            pasteboard: NSPasteboard(name: .init("OpenFindTests.\(UUID())"))
        )
        let day: TimeInterval = 24 * 60 * 60
        let now = Date(timeIntervalSince1970: 10 * day)
        store.setRetentionPeriod(.days3, referenceDate: now)

        #expect(store.ingest(
            representations: ["public.utf8-plain-text": Data("pinned".utf8)],
            previewText: "old pinned",
            kind: .text,
            createdAt: now.addingTimeInterval(-4 * day)
        ))
        store.togglePinned(try #require(store.entries.first))
        #expect(store.ingest(
            representations: ["public.utf8-plain-text": Data("expired".utf8)],
            previewText: "expired",
            kind: .text,
            createdAt: now.addingTimeInterval(-3 * day - 1)
        ))
        #expect(store.ingest(
            representations: ["public.utf8-plain-text": Data("boundary".utf8)],
            previewText: "boundary",
            kind: .text,
            createdAt: now.addingTimeInterval(-3 * day)
        ))
        #expect(store.ingest(
            representations: ["public.utf8-plain-text": Data("recent".utf8)],
            previewText: "recent",
            kind: .text,
            createdAt: now
        ))

        #expect(Set(store.entries.map(\.previewText)) == ["old pinned", "boundary", "recent"])
        #expect(store.entries.first(where: { $0.previewText == "old pinned" })?.isPinned == true)
    }

    @Test func foreverRetentionDisablesAgeBasedCleanup() throws {
        let suite = "OpenFindTests.Clipboard.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ClipboardHistoryStore(
            defaults: defaults,
            persistence: MemoryClipboardPersistence(),
            pasteboard: NSPasteboard(name: .init("OpenFindTests.\(UUID())"))
        )
        store.setRetentionPeriod(.forever)
        #expect(store.ingest(
            representations: ["public.utf8-plain-text": Data("ancient".utf8)],
            previewText: "ancient",
            kind: .text,
            createdAt: Date(timeIntervalSince1970: 1)
        ))

        #expect(!store.trimToLimits(referenceDate: Date(timeIntervalSince1970: 10_000_000)))
        #expect(store.entries.map(\.previewText) == ["ancient"])
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

    @Test func loadedPinnedItemsAreNeverSilentlyTrimmed() throws {
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
        #expect(store.entries.count == 4)
        #expect(retainedBytes == payload.count * 4)
        #expect(store.entries.allSatisfy { $0.isPinned })
    }

    @Test func foreverRetentionKeepsMoreThanTheLegacyThousandItemLimit() throws {
        let suite = "OpenFindTests.Clipboard.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let loaded = (0..<5_000).map { index in
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
        store.setRetentionPeriod(.forever)

        #expect(store.ingest(
            representations: ["public.utf8-plain-text": Data("new".utf8)],
            previewText: "new",
            kind: .text
        ))
        #expect(store.entries.count == 5_001)
        #expect(store.entries.first?.previewText == "new")
        #expect(store.entries.dropFirst().allSatisfy { $0.isPinned })
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

        store.setPasteWithoutFormatting(true)
        store.setClearHistoryOnQuit(true)
        store.setClearSystemClipboardOnQuit(true)
        store.setFuzzySearchEnabled(true)

        let reloaded = ClipboardHistoryStore(
            defaults: defaults,
            persistence: persistence,
            pasteboard: pasteboard
        )
        #expect(reloaded.pasteWithoutFormatting)
        #expect(reloaded.clearHistoryOnQuit)
        #expect(reloaded.clearSystemClipboardOnQuit)
        #expect(reloaded.fuzzySearchEnabled)
    }

    @Test(arguments: [1_000, 5_000])
    func cachedProjectionKeepsSearchAndPointerSelectionResponsive(itemCount: Int) throws {
        let suite = "OpenFindTests.ClipboardProjection.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date()
        let loaded = (0..<itemCount).map { index in
            let value = String(format: "item %05d needle-%05d", index, index)
            return ClipboardEntry(
                createdAt: now.addingTimeInterval(-TimeInterval(index)),
                previewText: value,
                kind: .text,
                representations: ["public.utf8-plain-text": Data(value.utf8)]
            )
        }
        let store = ClipboardHistoryStore(
            defaults: defaults,
            persistence: MemoryClipboardPersistence(savedEntries: loaded),
            pasteboard: NSPasteboard(name: .init("OpenFindTests.\(UUID())"))
        )

        let coldStart = ContinuousClock.now
        let visible = store.filteredEntries
        let coldDuration = coldStart.duration(to: .now)
        #expect(visible.count == itemCount)
        #expect(store.clipboardProjectionBuildCount == 1)

        let pointerStart = ContinuousClock.now
        for entry in visible {
            store.select(entry, preservingMultiSelection: true)
        }
        for _ in 0..<20_000 {
            _ = store.filteredEntries.count
        }
        let pointerDuration = pointerStart.duration(to: .now)
        #expect(store.clipboardProjectionBuildCount == 1)
        #expect(store.selectedIndex == itemCount - 1)

        store.query = "needle-\(String(format: "%05d", itemCount - 1))"
        let searchStart = ContinuousClock.now
        let matches = store.filteredEntries
        let searchDuration = searchStart.duration(to: .now)
        #expect(matches.count == 1)
        #expect(matches.first?.previewText.hasSuffix(String(format: "%05d", itemCount - 1)) == true)
        #expect(store.clipboardProjectionBuildCount == 2)

        // Guard the interaction budget, not merely eventual completion. A
        // quarter second regression is already visible in a transient panel.
        #expect(coldDuration < .milliseconds(250))
        #expect(pointerDuration < .milliseconds(250))
        #expect(searchDuration < .milliseconds(250))
    }

    @Test func unchangedEmptyQueryKeepsTheWarmProjection() throws {
        let suite = "OpenFindTests.ClipboardWarmProjection.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ClipboardHistoryStore(
            defaults: defaults,
            persistence: MemoryClipboardPersistence(savedEntries: [ClipboardEntry(
                previewText: "warm",
                kind: .text,
                representations: ["public.utf8-plain-text": Data("warm".utf8)]
            )]),
            pasteboard: NSPasteboard(name: .init("OpenFindTests.\(UUID())"))
        )
        _ = store.filteredEntries
        #expect(store.clipboardProjectionBuildCount == 1)

        store.query = ""
        _ = store.filteredEntries

        #expect(store.clipboardProjectionBuildCount == 1)
    }

    @Test func imagePreviewUsesBoundedDownsamplingAndHeaderOnlyDimensions() throws {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2_000,
            pixelsHigh: 1_000,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let entry = ClipboardEntry(
            previewText: "Image",
            kind: .image,
            representations: ["public.png": data]
        )

        let thumbnail = try #require(entry.downsampledPreviewImage(maxPixelSize: 256))

        #expect(thumbnail.size.width <= 256)
        #expect(thumbnail.size.height <= 256)
        #expect(abs((thumbnail.size.width / thumbnail.size.height) - 2) < 0.01)
        #expect(entry.imageDimensions == "2000×1000")
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

    @Test func structuredFiltersComposeWithTextSearchAndKeepOnlyTextHighlighted() throws {
        let suite = "OpenFindTests.ClipboardStructuredSearch.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date()
        let matching = ClipboardEntry(
            createdAt: now,
            previewText: "Image",
            kind: .image,
            representations: ["public.png": Data([1])],
            sourceBundleIdentifier: "com.google.Chrome",
            sourceApplicationName: "Google Chrome",
            recognizedText: "Invoice total 42"
        )
        let wrongApplication = ClipboardEntry(
            createdAt: now.addingTimeInterval(-1),
            previewText: "Image",
            kind: .image,
            representations: ["public.png": Data([2])],
            sourceBundleIdentifier: "com.apple.Safari",
            sourceApplicationName: "Safari",
            recognizedText: "Invoice total 99"
        )
        let savedSnippet = ClipboardEntry(
            createdAt: now.addingTimeInterval(-2),
            previewText: "Reusable reply",
            kind: .text,
            representations: ["public.utf8-plain-text": Data("Reusable reply".utf8)],
            isPinned: true,
            snippetCollection: "Work Replies",
            snippetKeyword: "reply",
            snippetExpansionEnabled: true
        )
        let store = ClipboardHistoryStore(
            defaults: defaults,
            persistence: MemoryClipboardPersistence(
                savedEntries: [matching, wrongApplication, savedSnippet]
            ),
            pasteboard: NSPasteboard(name: .init("OpenFindTests.\(UUID())"))
        )

        store.query = #"invoice app:"Google Chrome" type:image"#

        #expect(store.filteredEntries.map(\.id) == [matching.id])
        #expect(store.highlightQuery == "invoice")
        #expect(store.hasStructuredSearchFilters)

        store.query = #"is:snippet collection:"Work Replies""#
        #expect(store.filteredEntries.map(\.id) == [savedSnippet.id])

        store.query = #"invoice app:"Google Chrome""#
        store.removeSearchFilters()
        #expect(store.query == "invoice")
        #expect(
            ClipboardStructuredQuery.token(field: .application, value: "Google Chrome")
                == #"app:"Google Chrome""#
        )
    }

    @Test func imageTextRecognitionRunsInBackgroundAndMakesImagesSearchableAndCopyable()
        async throws {
        let suite = "OpenFindTests.ClipboardImageTextRecognition.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let pasteboard = NSPasteboard(name: .init("OpenFindTests.\(UUID())"))
        let image = ClipboardEntry(
            previewText: "Image",
            kind: .image,
            representations: ["public.png": Data([1, 2, 3])]
        )
        let persistence = MemoryClipboardPersistence(savedEntries: [image])
        let store = ClipboardHistoryStore(
            defaults: defaults,
            persistence: persistence,
            pasteboard: pasteboard,
            imageTextRecognizer: StubClipboardImageTextRecognizer(
                recognizedText: "Invoice total 42"
            ),
            imageTextRecognitionStartDelay: .zero
        )

        await store.waitForPendingImageTextRecognition()

        let recognized = try #require(store.entries.first)
        #expect(recognized.recognizedText == "Invoice total 42")
        store.query = "total 42"
        #expect(store.filteredEntries.map(\.id) == [image.id])
        #expect(store.canCopyPlainText(recognized))
        try store.copy(recognized, plainTextOnly: true)
        #expect(pasteboard.string(forType: .string) == "Invoice total 42")
        #expect(persistence.savedEntries.first?.recognizedText == "Invoice total 42")
    }

    @Test func recognizedSensitiveImageTextIsRejectedBeforeItRemainsInHistory()
        async throws {
        let suite = "OpenFindTests.ClipboardImageTextPrivacy.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var preferences = ClipboardPreferences()
        preferences.ignoredTextPatterns = [#"^PASSWORD \d+$"#]
        ClipboardPreferencesPersistence.save(preferences, to: defaults)
        let persistence = MemoryClipboardPersistence(savedEntries: [ClipboardEntry(
            previewText: "Image",
            kind: .image,
            representations: ["public.png": Data([9])]
        )])
        let store = ClipboardHistoryStore(
            defaults: defaults,
            persistence: persistence,
            pasteboard: NSPasteboard(name: .init("OpenFindTests.\(UUID())")),
            imageTextRecognizer: StubClipboardImageTextRecognizer(
                recognizedText: "PASSWORD 123456"
            ),
            imageTextRecognitionStartDelay: .zero
        )

        await store.waitForPendingImageTextRecognition()

        #expect(store.entries.isEmpty)
        #expect(persistence.savedEntries.isEmpty)
    }

    @Test func imageTextBecomesSearchableWhileClipboardPanelIsPresented() async throws {
        let suite = "OpenFindTests.ClipboardImageTextPresentation.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let recognizedText = "下午三点开会"
        let recognizer = CountingClipboardImageTextRecognizer(recognizedText: recognizedText)
        let image = ClipboardEntry(
            previewText: "Image",
            kind: .image,
            representations: ["public.png": Data([4, 5, 6])]
        )
        let store = ClipboardHistoryStore(
            defaults: defaults,
            persistence: MemoryClipboardPersistence(savedEntries: [image]),
            pasteboard: NSPasteboard(name: .init("OpenFindTests.\(UUID())")),
            imageTextRecognizer: recognizer,
            imageTextRecognitionStartDelay: .milliseconds(20)
        )

        store.beginPresentation()
        store.query = recognizedText
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await recognizer.callCount == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let callsWhilePresented = await recognizer.callCount
        #expect(callsWhilePresented == 1)
        #expect(store.filteredEntries.map(\.id) == [image.id])

        store.endPresentation()
        await store.waitForPendingImageTextRecognition()
    }

    @Test func emptyImageTextFromAnEarlierRecognizerIsRetried() async throws {
        let suite = "OpenFindTests.ClipboardImageTextRetry.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let recognizedText = "下午三点开会"
        let recognizer = CountingClipboardImageTextRecognizer(recognizedText: recognizedText)
        let image = ClipboardEntry(
            previewText: "Image",
            kind: .image,
            representations: ["public.png": Data([7, 8, 9])],
            recognizedText: ""
        )
        let store = ClipboardHistoryStore(
            defaults: defaults,
            persistence: MemoryClipboardPersistence(savedEntries: [image]),
            pasteboard: NSPasteboard(name: .init("OpenFindTests.\(UUID())")),
            imageTextRecognizer: recognizer,
            imageTextRecognitionStartDelay: .zero
        )

        await store.waitForPendingImageTextRecognition()

        #expect(await recognizer.callCount == 1)
        #expect(store.entries.first?.recognizedText == recognizedText)
    }

    @Test func currentEmptyImageTextIsNotRepeatedlyRetried() async throws {
        let suite = "OpenFindTests.ClipboardImageTextNoRepeat.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let recognizer = CountingClipboardImageTextRecognizer(recognizedText: "unexpected")
        let image = ClipboardEntry(
            previewText: "Image",
            kind: .image,
            representations: ["public.png": Data([10, 11, 12])],
            recognizedText: "",
            imageTextRecognitionRevision: 1
        )
        let store = ClipboardHistoryStore(
            defaults: defaults,
            persistence: MemoryClipboardPersistence(savedEntries: [image]),
            pasteboard: NSPasteboard(name: .init("OpenFindTests.\(UUID())")),
            imageTextRecognizer: recognizer,
            imageTextRecognitionStartDelay: .zero
        )

        await store.waitForPendingImageTextRecognition()

        #expect(await recognizer.callCount == 0)
        #expect(store.entries.first?.recognizedText == "")
    }

    @Test func deletionAndClearCanBeUndoneWithoutDiscardingNewCaptures() throws {
        let suite = "OpenFindTests.ClipboardDeletionUndo.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ClipboardHistoryStore(
            defaults: defaults,
            persistence: MemoryClipboardPersistence(),
            pasteboard: NSPasteboard(name: .init("OpenFindTests.\(UUID())"))
        )
        for (index, value) in ["oldest", "middle", "newest"].enumerated() {
            #expect(store.ingest(
                representations: ["public.utf8-plain-text": Data(value.utf8)],
                previewText: value,
                kind: .text,
                createdAt: Date(timeIntervalSince1970: TimeInterval(index + 1))
            ))
        }
        let middle = try #require(store.entries.first { $0.previewText == "middle" })
        store.select(middle)

        store.delete(middle)

        #expect(store.canUndoDeletion)
        #expect(store.undoDeletionCount == 1)
        #expect(store.undoLastDeletion())
        #expect(store.entries.map(\.previewText) == ["newest", "middle", "oldest"])
        #expect(store.selectedEntry?.id == middle.id)

        store.clearAll()
        #expect(store.undoDeletionCount == 3)
        #expect(store.ingest(
            representations: ["public.utf8-plain-text": Data("captured later".utf8)],
            previewText: "captured later",
            kind: .text,
            createdAt: Date(timeIntervalSince1970: 4)
        ))
        #expect(store.undoLastDeletion())
        #expect(store.entries.map(\.previewText) == [
            "captured later", "newest", "middle", "oldest",
        ])
        #expect(!store.canUndoDeletion)
    }
}

private final class MemoryClipboardPersistence: ClipboardHistoryPersisting {
    private(set) var savedEntries: [ClipboardEntry]
    private(set) var removeCount = 0
    private(set) var loadCount = 0
    private(set) var saveCount = 0
    var requiresExplicitMigration: Bool

    init(
        savedEntries: [ClipboardEntry] = [],
        requiresExplicitMigration: Bool = false
    ) {
        self.savedEntries = savedEntries
        self.requiresExplicitMigration = requiresExplicitMigration
    }

    func load() throws -> [ClipboardEntry] {
        loadCount += 1
        requiresExplicitMigration = false
        return savedEntries
    }

    func save(_ entries: [ClipboardEntry]) throws {
        saveCount += 1
        savedEntries = entries
    }

    func remove() throws {
        savedEntries = []
        removeCount += 1
    }
}

private struct StubClipboardImageTextRecognizer: ClipboardImageTextRecognizing {
    let recognizedText: String?

    func recognizeText(in _: Data) async -> String? {
        recognizedText
    }
}

private actor CountingClipboardImageTextRecognizer: ClipboardImageTextRecognizing {
    let recognizedText: String?
    private(set) var callCount = 0

    init(recognizedText: String?) {
        self.recognizedText = recognizedText
    }

    func recognizeText(in _: Data) async -> String? {
        callCount += 1
        return recognizedText
    }
}

private final class MemoryClipboardKeychain: ClipboardHistoryKeychainAccessing {
    var data: Data?
    private(set) var readCount = 0
    private(set) var storeCount = 0

    func read() throws -> Data? {
        readCount += 1
        return data
    }

    func store(_ data: Data) throws {
        storeCount += 1
        self.data = data
    }

    func remove() throws {
        data = nil
    }
}

private func seedLegacyHistory(
    _ entries: [ClipboardEntry],
    defaults: UserDefaults,
    keychain: MemoryClipboardKeychain
) throws {
    let keyData = Data(repeating: 19, count: 32)
    keychain.data = keyData
    let encoded = try JSONEncoder().encode(entries)
    let sealed = try AES.GCM.seal(encoded, using: SymmetricKey(data: keyData))
    defaults.set(
        sealed.combined,
        forKey: EncryptedClipboardHistoryPersistence.ciphertextKey
    )
}

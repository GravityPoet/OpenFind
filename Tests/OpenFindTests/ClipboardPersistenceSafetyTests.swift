import AppKit
import Foundation
import Testing
@testable import OpenFind

/// Regression coverage for the history wipe-out found in the field: a
/// transient load failure at launch left the session with an empty in-memory
/// list, and the next save deleted every row still safe on disk.
@Suite("Clipboard Persistence Safety Tests")
@MainActor
struct ClipboardPersistenceSafetyTests {
    private final class SafetyKeychain: ClipboardHistoryKeychainAccessing {
        var data: Data?
        func read() throws -> Data? { data }
        func store(_ data: Data) throws { self.data = data }
        func remove() throws { data = nil }
    }

    private final class FailingLoadPersistence: ClipboardHistoryPersisting {
        private(set) var saveCount = 0
        func load() throws -> [ClipboardEntry] {
            throw ClipboardHistoryError.persistenceUnavailable
        }
        func save(_ entries: [ClipboardEntry]) throws { saveCount += 1 }
        func remove() throws {}
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenFindSafetyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func entry(_ text: String) -> ClipboardEntry {
        ClipboardEntry(
            previewText: text,
            kind: .text,
            representations: ["public.utf8-plain-text": Data(text.utf8)]
        )
    }

    @Test func loadFailureDegradesToMemoryOnlyCaptureInsteadOfOverwriting() throws {
        let suite = "OpenFindTests.PersistenceSafety.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let persistence = FailingLoadPersistence()
        let store = ClipboardHistoryStore(
            defaults: defaults,
            persistence: persistence,
            pasteboard: NSPasteboard(name: .init("OpenFindTests.\(UUID())"))
        )

        #expect(store.isPersistenceDegraded)
        #expect(store.entries.isEmpty)

        #expect(store.ingest(
            representations: ["public.utf8-plain-text": Data("fresh".utf8)],
            previewText: "fresh",
            kind: .text
        ))
        #expect(store.entries.count == 1)
        #expect(persistence.saveCount == 0)
        #expect(
            store.lastErrorMessage
                == ClipboardHistoryError.persistenceDesynchronized.localizedDescription
        )
    }

    @Test func saveRefusesToDeleteRowsTheSessionNeverRead() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "OpenFindTests.PersistenceSafety.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let keyURL = directory.appendingPathComponent("key", isDirectory: false)
        let databaseURL = directory.appendingPathComponent("history.sqlite3", isDirectory: false)
        let keychain = SafetyKeychain()

        let writer = EncryptedClipboardHistoryPersistence(
            defaults: defaults,
            keyFileURL: keyURL,
            databaseURL: databaseURL,
            keychain: keychain,
            signingTeamIdentifier: nil
        )
        let saved = [entry("one"), entry("two"), entry("three")]
        try writer.save(saved)

        // A second session that never managed to read the store must not be
        // able to delete what it never saw.
        let desynchronized = EncryptedClipboardHistoryPersistence(
            defaults: defaults,
            keyFileURL: keyURL,
            databaseURL: databaseURL,
            keychain: keychain,
            signingTeamIdentifier: nil
        )
        #expect(throws: ClipboardHistoryError.persistenceDesynchronized) {
            try desynchronized.save([self.entry("only-new")])
        }

        let reader = EncryptedClipboardHistoryPersistence(
            defaults: defaults,
            keyFileURL: keyURL,
            databaseURL: databaseURL,
            keychain: keychain,
            signingTeamIdentifier: nil
        )
        let survived = try reader.load()
        #expect(survived.count == 3)
        #expect(Set(survived.map(\.previewText)) == ["one", "two", "three"])
    }

    @Test func sessionsThatLoadedTheStoreCanStillClearIt() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "OpenFindTests.PersistenceSafety.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let keyURL = directory.appendingPathComponent("key", isDirectory: false)
        let databaseURL = directory.appendingPathComponent("history.sqlite3", isDirectory: false)
        let keychain = SafetyKeychain()

        let writer = EncryptedClipboardHistoryPersistence(
            defaults: defaults,
            keyFileURL: keyURL,
            databaseURL: databaseURL,
            keychain: keychain,
            signingTeamIdentifier: nil
        )
        try writer.save([entry("one"), entry("two")])

        let session = EncryptedClipboardHistoryPersistence(
            defaults: defaults,
            keyFileURL: keyURL,
            databaseURL: databaseURL,
            keychain: keychain,
            signingTeamIdentifier: nil
        )
        #expect(try session.load().count == 2)
        try session.save([])

        let reader = EncryptedClipboardHistoryPersistence(
            defaults: defaults,
            keyFileURL: keyURL,
            databaseURL: databaseURL,
            keychain: keychain,
            signingTeamIdentifier: nil
        )
        #expect(try reader.load().isEmpty)
    }
}

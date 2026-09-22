import AppKit
import Foundation
import Testing
@testable import OpenFind

@MainActor
@Suite(.serialized)
struct ConfigurationTransferTests {
    @Test func atomicFileRejectsStaleWritesSymlinksAndMissingFolders() async throws {
        let context = try ConfigurationTestContext()
        defer { context.cleanup() }
        let file = context.directory.appendingPathComponent("settings.json")
        let initial = Data("one".utf8)
        #expect(try await ConfigurationFile.read(file) == nil)
        try await ConfigurationFile.write(initial, to: file, replacing: nil)
        await #expect(throws: ConfigurationError.conflict) {
            try await ConfigurationFile.write(Data("two".utf8), to: file, replacing: Data())
        }
        #expect(try await ConfigurationFile.read(file) == initial)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let link = context.directory.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        await #expect(throws: ConfigurationError.invalidPreferences) { try await ConfigurationFile.read(link) }
        let missing = context.directory.appendingPathComponent("missing/settings.json")
        await #expect(throws: ConfigurationError.missingFile) {
            try await ConfigurationFile.write(initial, to: missing, replacing: nil)
        }
    }

    @Test func invalidArchiveCannotChangePreferencesOrHistory() async throws {
        let context = try ConfigurationTestContext()
        defer { context.cleanup() }
        let before = try context.transfer.snapshot()
        var unknown = before
        unknown.preferences["unrecognized-key"] = Data()
        await #expect(throws: ConfigurationError.invalidPreferences) { try await context.transfer.apply(unknown) }
        var invalid = before
        invalid.preferences["OpenFind.globalHotKeyKeyCode"] = try PropertyListSerialization.data(
            fromPropertyList: [100_000], format: .binary, options: 0)
        await #expect(throws: ConfigurationError.invalidPreferences) { try await context.transfer.apply(invalid) }
        #expect(try context.transfer.snapshot() == before)
        #expect(!context.sync.hasRecovery)
    }

    @Test func importAppliesPortableSettingsPreservesHistoryAndRestoresPreviousSnapshot() async throws {
        let source = try ConfigurationTestContext(), target = try ConfigurationTestContext()
        defer { source.cleanup(); target.cleanup() }
        source.defaults.set("compact", forKey: OpenFindInterfaceSize.persistenceKey)
        source.defaults.set(0.35, forKey: "OpenFind.keyboardLockPanelOpacityV1")
        source.clipboard.setSnippetExpansionEnabled(true)
        source.clipboard.setQuickMergeEnabled(true)
        _ = try source.clipboard.createSnippet(name: "Work", content: "Synthetic snippet", keyword: "!work")
        target.clipboard.setCapturePaused(true)
        target.clipboard.setPreference(\.popupScreen, to: 3)
        let history = ClipboardEntry(previewText: "Local only", kind: .text,
            representations: [NSPasteboard.PasteboardType.string.rawValue: Data("Local only".utf8)])
        target.clipboard.entries.append(history)
        _ = target.clipboard.persist()
        target.defaults.set(Data([1, 2]), forKey: "search.scopeBookmarks")
        let before = try target.transfer.snapshot()
        let archive = try source.transfer.snapshot()
        #expect(archive.snippets.count == 1)
        #expect(archive.preferences["search.scopeBookmarks"] == nil)
        var reloads = 0
        target.transfer.reload = { reloads += 1 }
        try await target.transfer.apply(archive)
        #expect(target.defaults.string(forKey: OpenFindInterfaceSize.persistenceKey) == "compact")
        #expect(target.defaults.double(forKey: "OpenFind.keyboardLockPanelOpacityV1") == 0.35)
        #expect(target.clipboard.preferences.snippetExpansionEnabled && target.clipboard.preferences.quickMergeEnabled)
        #expect(target.clipboard.preferences.capturePaused && target.clipboard.preferences.popupScreen == 3)
        #expect(target.clipboard.entries.contains(history))
        #expect(target.defaults.data(forKey: "search.scopeBookmarks") == Data([1, 2]))
        #expect(try target.transfer.snapshot() == archive)
        let recovery = try #require(try await ConfigurationFile.read(target.transfer.recoveryURL))
        #expect(try ConfigurationArchive.decode(recovery) == before)
        try await target.transfer.apply(archive)
        #expect(reloads == 1)
        await target.sync.restore()
        #expect(try target.transfer.snapshot() == before)
        #expect(target.clipboard.entries.contains(history))
    }

    @Test func persistenceFailureRollsBackBeforePreferencesChange() async throws {
        let context = try ConfigurationTestContext()
        defer { context.cleanup() }
        _ = try context.clipboard.createSnippet(name: "Before", content: "before")
        let before = try context.transfer.snapshot()
        let entries = context.clipboard.entries
        var changed = before
        changed.snippets[0].content = "after"
        context.persistence.failSave = true
        await #expect(throws: ConfigurationError.saveFailed) { try await context.transfer.apply(changed) }
        #expect(try context.transfer.snapshot() == before)
        #expect(context.clipboard.entries == entries)
    }

    @Test func portableCaptureStateIsLocalWhileExpansionAndMergeTravel() throws {
        var preferences = ClipboardPreferences()
        preferences.capturePaused = true
        preferences.ignoreOnlyNextCapture = true
        preferences.popupScreen = 6
        preferences.snippetExpansionEnabled = true
        preferences.quickMergeEnabled = true
        let portable = try ConfigurationPreferenceKeys.portableClipboardData(JSONEncoder().encode(preferences))
        let decoded = try JSONDecoder().decode(ClipboardPreferences.self, from: portable)
        #expect(!decoded.capturePaused && !decoded.ignoreOnlyNextCapture && decoded.popupScreen == 0)
        #expect(decoded.snippetExpansionEnabled && decoded.quickMergeEnabled)
    }
}

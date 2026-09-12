import AppKit
import Foundation
import Testing
@testable import OpenFind

@MainActor
final class ConfigurationTestContext {
    let suite = "OpenFindTests.Config.\(UUID())"
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OpenFindConfig-\(UUID())")
    let defaults: UserDefaults
    let persistence = ConfigurationMemoryPersistence()
    let clipboard: ClipboardHistoryStore
    let transfer: ConfigurationTransferStore
    let sync: ConfigurationSyncController

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        clipboard = ClipboardHistoryStore(defaults: defaults, persistence: persistence,
            pasteboard: NSPasteboard(name: .init(suite)))
        transfer = ConfigurationTransferStore(defaults: defaults, clipboard: clipboard,
            recoveryURL: directory.appendingPathComponent("state/recovery.json"), domainName: suite)
        sync = ConfigurationSyncController(transfer: transfer, defaults: defaults)
    }

    func cleanup() {
        sync.stop()
        clipboard.pauseImageTextRecognitionForBackground()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

final class ConfigurationMemoryPersistence: ClipboardHistoryPersisting {
    var entries: [ClipboardEntry] = []
    var failSave = false
    var saves = 0
    func load() throws -> [ClipboardEntry] { entries }
    func save(_ entries: [ClipboardEntry]) throws {
        if failSave { throw ConfigurationError.saveFailed }
        self.entries = entries
        saves += 1
    }
    func remove() throws { entries = [] }
}

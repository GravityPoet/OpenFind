import Foundation
import Testing
@testable import OpenFind

@MainActor
@Suite(.serialized)
struct ConfigurationSyncTests {
    @Test func divergentOfflineWritesAreConflictsEvenAfterEachClientSavedItsBaseline() async throws {
        let first = try ConfigurationTestContext(), second = try ConfigurationTestContext()
        defer { first.cleanup(); second.cleanup() }
        await first.sync.connect(first.directory)
        first.sync.stop()
        await second.sync.connect(first.directory)
        second.sync.stop()
        let file = try #require(first.sync.syncURL)
        let initial = try #require(try await ConfigurationFile.read(file))
        first.defaults.set("large", forKey: OpenFindInterfaceSize.persistenceKey)
        await first.sync.synchronize()
        let firstWrite = try #require(try await ConfigurationFile.read(file))
        // Model the second Mac's offline replica still containing the old file.
        try await ConfigurationFile.write(initial, to: file, replacing: firstWrite)
        second.defaults.set("compact", forKey: OpenFindInterfaceSize.persistenceKey)
        await second.sync.synchronize()
        let secondWrite = try #require(try await ConfigurationFile.read(file))
        await first.sync.synchronize()
        #expect(first.sync.hasConflict)
        #expect(first.defaults.string(forKey: OpenFindInterfaceSize.persistenceKey) == "large")
        #expect(try await ConfigurationFile.read(file) == secondWrite)
        await first.sync.resolveConflict(useLocal: false)
        #expect(!first.sync.hasConflict)
        await second.sync.synchronize()
        #expect(!second.sync.hasConflict)
        #expect(try first.transfer.snapshot() == second.transfer.snapshot())
    }

    @Test func twoClientsSyncChangesDetectConflictsAndKeepRemoteBackup() async throws {
        let first = try ConfigurationTestContext(), second = try ConfigurationTestContext()
        defer { first.cleanup(); second.cleanup() }
        let folder = first.directory.appendingPathComponent("shared")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        await first.sync.connect(folder)
        first.sync.stop()
        await second.sync.connect(folder)
        second.sync.stop()
        #expect(!first.sync.hasConflict && !second.sync.hasConflict)
        first.defaults.set("compact", forKey: OpenFindInterfaceSize.persistenceKey)
        await first.sync.synchronize()
        await second.sync.synchronize()
        #expect(second.defaults.string(forKey: OpenFindInterfaceSize.persistenceKey) == "compact")
        #expect(try first.transfer.snapshot() == second.transfer.snapshot())
        let file = try #require(first.sync.syncURL)
        let unchanged = try await ConfigurationFile.read(file)
        await second.sync.synchronize()
        #expect(try await ConfigurationFile.read(file) == unchanged)
        first.defaults.set("large", forKey: OpenFindInterfaceSize.persistenceKey)
        second.defaults.set("standard", forKey: OpenFindInterfaceSize.persistenceKey)
        await first.sync.synchronize()
        await second.sync.synchronize()
        #expect(second.sync.hasConflict)
        #expect(second.defaults.string(forKey: OpenFindInterfaceSize.persistenceKey) == "standard")
        let remoteBefore = try await ConfigurationFile.read(file)
        await second.sync.resolveConflict(useLocal: true)
        #expect(!second.sync.hasConflict)
        let backups = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("OpenFind-Conflict-") }
        #expect(backups.count == 1)
        #expect(try await ConfigurationFile.read(#require(backups.first)) == remoteBefore)
        await first.sync.synchronize()
        #expect(first.defaults.string(forKey: OpenFindInterfaceSize.persistenceKey) == "standard")
        try FileManager.default.removeItem(at: file)
        await first.sync.synchronize()
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func firstConnectionAndChangingFolderNeverOverwriteUnrelatedConfigurations() async throws {
        let first = try ConfigurationTestContext(), second = try ConfigurationTestContext()
        defer { first.cleanup(); second.cleanup() }
        first.defaults.set("large", forKey: OpenFindInterfaceSize.persistenceKey)
        await first.sync.connect(first.directory)
        first.sync.stop()
        await second.sync.connect(first.directory)
        second.sync.stop()
        #expect(second.sync.hasConflict)
        await second.sync.resolveConflict(useLocal: false)
        #expect(second.defaults.string(forKey: OpenFindInterfaceSize.persistenceKey) == "large")
        #expect(second.sync.hasRecovery)
        let newFolder = second.directory.appendingPathComponent("new-folder")
        try FileManager.default.createDirectory(at: newFolder, withIntermediateDirectories: true)
        await second.sync.connect(newFolder)
        second.sync.stop()
        #expect(!second.sync.hasConflict)
        #expect(FileManager.default.fileExists(atPath: newFolder.appendingPathComponent("OpenFind-Configuration.json").path))
        await second.sync.restore()
        #expect(second.defaults.string(forKey: OpenFindInterfaceSize.persistenceKey) == nil)
        #expect(second.sync.folder == nil)
    }
}

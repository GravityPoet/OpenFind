import Foundation
import Testing
@testable import OpenFind

@MainActor
@Suite("Drive Alive Store Tests")
struct DriveAliveStoreTests {
    @Test func storesPoliciesAndReloadsTargets() throws {
        let suite = "OpenFindTests.DriveAliveStore.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let resolver = FakeDriveAliveResolver()
        let directory = FileManager.default.temporaryDirectory
        let store = DriveAliveStore(defaults: defaults, resolver: resolver)
        let id = try store.add(directoryURL: directory, policy: .whileOpenFindRuns)
        try store.setInterval(30)
        store.setEnabled(true)

        let reloaded = DriveAliveStore(defaults: defaults, resolver: resolver)
        #expect(reloaded.isEnabled)
        #expect(reloaded.interval == 30)
        #expect(reloaded.targets.count == 1)
        #expect(reloaded.targets.first?.id == id)
        #expect(reloaded.targets.first?.policy == .whileOpenFindRuns)
    }

    @Test func rejectsDuplicateTargetsAndInvalidIntervals() throws {
        let suite = "OpenFindTests.DriveAliveStore.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let resolver = FakeDriveAliveResolver()
        let store = DriveAliveStore(defaults: defaults, resolver: resolver)
        let directory = FileManager.default.temporaryDirectory
        _ = try store.add(directoryURL: directory)

        #expect(throws: DriveAliveStoreError.duplicateTarget) {
            try store.add(directoryURL: directory)
        }
        #expect(throws: DriveAliveStoreError.invalidInterval) {
            try store.setInterval(0.5)
        }
        #expect(throws: DriveAliveStoreError.invalidInterval) {
            try store.setInterval(.infinity)
        }
    }

    @Test func rejectsARegularFileInsteadOfPersistingAnUnwritableTarget() throws {
        let suite = "OpenFindTests.DriveAliveFileTarget.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenFindDriveAliveFile.\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        #expect(throws: DriveAliveStoreError.invalidTarget) {
            try DriveAliveStore(
                defaults: defaults,
                resolver: FakeDriveAliveResolver()
            ).add(directoryURL: file)
        }
    }

    @Test func corruptConfigurationIsLeftUntouched() throws {
        let suite = "OpenFindTests.DriveAliveStore.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let corrupt = Data([0x01, 0x02, 0x03])
        defaults.set(corrupt, forKey: "OpenFind.driveAliveTargetsV1")

        let store = DriveAliveStore(defaults: defaults, resolver: FakeDriveAliveResolver())

        #expect(store.targets.isEmpty)
        #expect(store.loadErrorMessage != nil)
        #expect(defaults.data(forKey: "OpenFind.driveAliveTargetsV1") == corrupt)
    }
}

private struct FakeDriveAliveResolver: DriveAliveBookmarkResolving {
    func bookmarkData(for directoryURL: URL) throws -> Data {
        Data(directoryURL.standardizedFileURL.path.utf8)
    }

    func resolve(_ bookmarkData: Data) throws -> DriveAliveResolvedResource {
        let path = String(decoding: bookmarkData, as: UTF8.self)
        return DriveAliveResolvedResource(url: URL(fileURLWithPath: path))
    }
}

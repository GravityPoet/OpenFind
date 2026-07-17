import Darwin
import Foundation
import Testing
@testable import OpenFind

@Suite("Bulk Directory Reader Tests", .serialized)
struct BulkDirectoryReaderTests {
    @Test func bulkMetadataMatchesFoundationNoFollowDirectoryEntries() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenFindBulkReader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("普通-file.txt")
        let hidden = root.appendingPathComponent(".hidden.txt")
        let flagged = root.appendingPathComponent("flagged.txt")
        let directory = root.appendingPathComponent("folder", isDirectory: true)
        try Data("bulk-reader".utf8).write(to: file)
        try Data("hidden".utf8).write(to: hidden)
        try Data("flagged".utf8).write(to: flagged)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("file-link"),
            withDestinationURL: file
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("directory-link"),
            withDestinationURL: directory
        )
        _ = flagged.path.withCString { chflags($0, UInt32(UF_HIDDEN)) }

        let bulk = try #require(try BulkDirectoryReader.read(path: root.path))
        let byName = Dictionary(uniqueKeysWithValues: bulk.map { ($0.name, $0) })
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
            .contentModificationDateKey, .creationDateKey, .isHiddenKey,
        ]
        let urls = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: []
        )

        #expect(Set(byName.keys) == Set(urls.map(\.lastPathComponent)))
        for url in urls {
            let expected = try url.resourceValues(forKeys: keys)
            let actual = try #require(byName[url.lastPathComponent])
            #expect(actual.isDirectory == (expected.isDirectory ?? false))
            #expect(actual.isSymbolicLink == (expected.isSymbolicLink ?? false))
            #expect(actual.size == Int64(expected.fileSize ?? 0))
            #expect(abs(actual.modifiedTime - (expected.contentModificationDate ?? .distantPast).timeIntervalSinceReferenceDate) < 0.001)
            let expectedCreated = expected.creationDate ?? expected.contentModificationDate ?? .distantPast
            #expect(abs(actual.creationTime - expectedCreated.timeIntervalSinceReferenceDate) < 0.001)
            #expect(actual.isHidden == (expected.isHidden ?? false))
        }

        #expect(byName["file-link"]?.isDirectory == false)
        #expect(byName["directory-link"]?.isDirectory == false)
        #expect(byName["directory-link"]?.isSymbolicLink == true)
        #expect(byName["flagged.txt"]?.isHidden == true)

        let topology = try #require(try BulkDirectoryReader.readTopology(path: root.path))
        let topologyByName = Dictionary(uniqueKeysWithValues: topology.map { ($0.name, $0) })
        #expect(Set(topologyByName.keys) == Set(byName.keys))
        for (name, metadata) in byName {
            let entry = try #require(topologyByName[name])
            #expect(entry.isDirectory == metadata.isDirectory)
            #expect(entry.isSymbolicLink == metadata.isSymbolicLink)
            #expect(entry.isHidden == metadata.isHidden)
        }
    }

    @Test func nonDirectoryReportsAnOperationalFailure() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenFindBulkReaderFile-\(UUID().uuidString)")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        #expect(throws: NSError.self) {
            _ = try BulkDirectoryReader.read(path: file.path)
        }
    }

    @Test func ancestorIdentityStopsAnAliasCycleWithoutGlobalDeduplication() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenFindBulkIdentity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("visible".utf8).write(to: root.appendingPathComponent("visible.txt"))
        defer { try? FileManager.default.removeItem(at: root) }

        var identity: BulkDirectoryIdentity?
        let first = try #require(try BulkDirectoryReader.read(
            path: root.path,
            claimIdentity: {
                identity = $0
                return true
            }
        ))
        #expect(first.map(\.name) == ["visible.txt"])

        let chain = DirectoryIdentityChain(identity: try #require(identity), parent: nil)
        let cycle = try #require(try BulkDirectoryReader.read(
            path: root.path,
            claimIdentity: { !chain.contains($0) }
        ))
        #expect(cycle.isEmpty)

        // The guard is ancestry-scoped. A separate user-visible root starts a
        // fresh chain and therefore remains fully searchable.
        let independent = try #require(try BulkDirectoryReader.read(path: root.path))
        #expect(independent.map(\.name) == ["visible.txt"])
    }

}

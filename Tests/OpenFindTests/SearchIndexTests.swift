import CoreServices
import Darwin
import Foundation
import Testing
@testable import OpenFind

private final class ThreadSafeNodeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []

    func append(_ nodes: [TempNode]) {
        lock.lock()
        paths.append(contentsOf: nodes.map(\.path))
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return paths
    }
}

private final class ThreadSafeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    func snapshot() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

@Suite("SearchIndex Tests")
struct SearchIndexTests {
    private func createTempDirectory() throws -> URL {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("OpenFindIndexTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    private func writeFile(at url: URL, content: String = "") throws {
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func createCacheURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("OpenFindIndexCache-\(UUID().uuidString).bin")
    }

    private func tempNode(path: String, isDirectory: Bool = false) -> TempNode {
        TempNode(
            path: path,
            name: path == "/" ? "/" : (path as NSString).lastPathComponent,
            isDirectory: isDirectory,
            size: 0,
            modifiedTime: 0,
            creationTime: 0,
            isHiddenScope: false,
            isPackageDescendant: false
        )
    }

    @Test func wholeMacRootNodeDoesNotCreateAParentCycle() {
        let root = TempNode(
            path: "/", name: "/", isDirectory: true, size: 0,
            modifiedTime: 0, creationTime: 0,
            isHiddenScope: false, isPackageDescendant: false
        )
        let child = TempNode(
            path: "/SearchQuery.swift", name: "SearchQuery.swift", isDirectory: false, size: 1,
            modifiedTime: 0, creationTime: 0,
            isHiddenScope: false, isPackageDescendant: false
        )

        let nodes = SearchIndexBuilder.assembleIndexedNodes(from: [root, child])
        let index = SearchIndex(
            signature: SearchIndexSignature(scopes: [URL(fileURLWithPath: "/")]),
            nodes: nodes
        )

        #expect(nodes[0].parentIndex == -1)
        #expect(index.path(for: 0) == "/")
        #expect(index.path(for: 1) == "/SearchQuery.swift")
    }

    @Test func cachedIndexWithSelfParentingNodeIsRejected() {
        let cacheURL = createCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let signature = SearchIndexSignature(scopes: [URL(fileURLWithPath: "/")])
        let corruptIndex = SearchIndex(
            signature: signature,
            nodes: [
                IndexedFileNode(
                    name: "/", parentIndex: 0, isDirectory: true, size: 0,
                    modifiedTime: 0, creationTime: 0,
                    isHiddenScope: false, isPackageDescendant: false
                ),
            ]
        )

        SearchIndexPersistence.save(index: corruptIndex, to: cacheURL)

        #expect(SearchIndexPersistence.load(signature: signature, from: cacheURL) == nil)
    }

    @Test func cachedIndexKeepsExplicitScopeAuthorizationInItsSignature() {
        let cacheURL = createCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let scopePath = "/Users/test/Downloads"
        let authorizedSignature = SearchIndexSignature(
            scopes: [URL(fileURLWithPath: scopePath)],
            hasFullDiskAccess: false,
            authorizedScopePaths: [scopePath]
        )
        let index = SearchIndex(
            signature: authorizedSignature,
            nodes: SearchIndexBuilder.assembleIndexedNodes(from: [
                tempNode(path: scopePath, isDirectory: true),
            ]),
            pathsAreFresh: true
        )

        SearchIndexPersistence.save(index: index, to: cacheURL)

        #expect(SearchIndexPersistence.load(
            signature: authorizedSignature,
            from: cacheURL
        ) != nil)
        let untrustedSignature = SearchIndexSignature(
            scopes: [URL(fileURLWithPath: scopePath)],
            hasFullDiskAccess: false
        )
        #expect(SearchIndexPersistence.load(
            signature: untrustedSignature,
            from: cacheURL
        ) == nil)
    }

    @Test func indexedNameSearchFindsFilesWithoutTraversalOptions() async throws {
        let root = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let visible = root.appendingPathComponent("cardinal_report.txt")
        let hidden = root.appendingPathComponent(".cardinal_secret.txt")
        try writeFile(at: visible)
        try writeFile(at: hidden)

        var options = SearchOptions()
        options.query = "cardinal"
        options.target = .name
        options.includeHidden = false

        let results = await collect(scopes: [root], options: options)
        #expect(results.map(\.name) == ["cardinal_report.txt"])

        options.includeHidden = true
        let hiddenResults = await collect(scopes: [root], options: options)
        #expect(Set(hiddenResults.map(\.name)) == Set(["cardinal_report.txt", ".cardinal_secret.txt"]))
    }

    @Test func completeSubtreeCompactionReplacesBaseWithoutDroppingSiblings() throws {
        let root = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let stableDirectory = root.appendingPathComponent("stable", isDirectory: true)
        let changedDirectory = root.appendingPathComponent("changed", isDirectory: true)
        let oldPath = changedDirectory.appendingPathComponent("old-result.txt").path
        let newPath = changedDirectory.appendingPathComponent("new-result.txt").path
        let stablePath = stableDirectory.appendingPathComponent("stable-result.txt").path
        let signature = SearchIndexSignature(scopes: [root])
        let base = SearchIndex(
            signature: signature,
            nodes: SearchIndexBuilder.assembleIndexedNodes(from: [
                tempNode(path: root.path, isDirectory: true),
                tempNode(path: stableDirectory.path, isDirectory: true),
                tempNode(path: stablePath),
                tempNode(path: changedDirectory.path, isDirectory: true),
                tempNode(path: oldPath),
            ])
        )
        let replacement = SearchIndexReplacement(
            rootPath: changedDirectory.path,
            nodes: [
                tempNode(path: changedDirectory.path, isDirectory: true),
                tempNode(path: newPath),
            ]
        )

        let compacted = base.compacting(completeReplacements: [replacement])
        let paths = Set((0..<compacted.nodes.count).map(compacted.path(for:)))

        #expect(paths.contains(root.path))
        #expect(paths.contains(stablePath))
        #expect(paths.contains(newPath))
        #expect(!paths.contains(oldPath))
        #expect(compacted.stats.indexedItems == 5)

        var options = SearchOptions()
        options.query = "new-result"
        options.target = .name
        #expect(compacted.nameMatches(
            query: try SearchQueryPlan.parse(options.query).compile(options: options),
            options: options
        ).map(\.path) == [newPath])
    }

    @Test func completeSubtreeCompactionResolvesSeveralRootsWithTheSameLeafName() throws {
        let root = URL(fileURLWithPath: "/tmp/openfind-shared-leaf-compaction")
        let first = root.appendingPathComponent("one/shared", isDirectory: true)
        let second = root.appendingPathComponent("two/shared", isDirectory: true)
        let signature = SearchIndexSignature(scopes: [root])
        let base = SearchIndex(
            signature: signature,
            nodes: SearchIndexBuilder.assembleIndexedNodes(from: [
                tempNode(path: root.path, isDirectory: true),
                tempNode(path: root.appendingPathComponent("one").path, isDirectory: true),
                tempNode(path: first.path, isDirectory: true),
                tempNode(path: first.appendingPathComponent("old-one.txt").path),
                tempNode(path: root.appendingPathComponent("two").path, isDirectory: true),
                tempNode(path: second.path, isDirectory: true),
                tempNode(path: second.appendingPathComponent("old-two.txt").path),
            ])
        )
        let replacements = [first, second].map { directory in
            SearchIndexReplacement(
                rootPath: directory.path,
                nodes: [
                    tempNode(path: directory.path, isDirectory: true),
                    tempNode(path: directory.appendingPathComponent("new.txt").path),
                ]
            )
        }

        let compacted = base.compacting(completeReplacements: replacements)
        let paths = Set(compacted.nodes.indices.map(compacted.path(for:)))

        #expect(paths.contains(first.appendingPathComponent("new.txt").path))
        #expect(paths.contains(second.appendingPathComponent("new.txt").path))
        #expect(!paths.contains(first.appendingPathComponent("old-one.txt").path))
        #expect(!paths.contains(second.appendingPathComponent("old-two.txt").path))
    }

    @Test func contentSearchUsesIndexedCandidates() async throws {
        let root = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeFile(at: root.appendingPathComponent("name_only.txt"), content: "nothing")
        try writeFile(at: root.appendingPathComponent("body.txt"), content: "needle in content")

        var options = SearchOptions()
        options.query = "needle"
        options.target = .content

        let results = await collect(scopes: [root], options: options)
        #expect(results.map(\.name) == ["body.txt"])
        #expect(results.first?.matchedContent == true)
    }

    @Test func eventPathCollapseKeepsMinimalAncestors() {
        let root = URL(fileURLWithPath: "/tmp/openfind-index")
        let signature = SearchIndexSignature(scopes: [root])
        let collapsed = SearchIndexBuilder.collapseEventPaths(
            [
                "/tmp/openfind-index/a/b/file.txt",
                "/tmp/openfind-index/a",
                "/tmp/openfind-index/z.txt",
                "/tmp/outside.txt",
            ],
            signature: signature
        )

        #expect(collapsed == ["/tmp/openfind-index/a", "/tmp/openfind-index/z.txt"])
    }

    @Test func eventPathCollapseFindsParentAcrossLexicalSibling() {
        let root = "/tmp/openfind-index"
        let signature = SearchIndexSignature(scopes: [URL(fileURLWithPath: root)])
        let collapsed = SearchIndexBuilder.collapseEventPaths(
            [
                "\(root)/a/b/c/result.txt",
                "\(root)/a/b-older-sibling",
                "\(root)/a/b",
            ],
            signature: signature
        )

        #expect(collapsed == ["\(root)/a/b", "\(root)/a/b-older-sibling"])
    }

    @Test func eventPathCollapseDropsIndexNoise() {
        let signature = SearchIndexSignature(scopes: [URL(fileURLWithPath: "/")])
        let collapsed = SearchIndexBuilder.collapseEventPaths(
            [
                "/private/tmp/openfind-noise/file.tmp",
                "\(NSHomeDirectory())/Library/Caches/OpenFind/noise.bin",
                "/Applications/OpenFind.app/Contents/Info.plist",
            ],
            signature: signature
        )

        #expect(collapsed == ["/Applications/OpenFind.app/Contents/Info.plist"])
    }

    @Test func eventPathCollapseScalesAcrossLargeSiblingBatches() {
        let root = "/tmp/openfind-large-event-collapse"
        let signature = SearchIndexSignature(scopes: [URL(fileURLWithPath: root)])
        var paths = (0..<30_000).map { index in
            String(format: "%@/folder-%05d/file.txt", root, index)
        }
        paths.append(contentsOf: paths.prefix(2_000))
        paths.append("\(root)/folder-00010")

        let collapsed = SearchIndexBuilder.collapseEventPaths(paths.reversed(), signature: signature)

        #expect(collapsed.count == 30_000)
        #expect(collapsed.contains("\(root)/folder-00010"))
        #expect(!collapsed.contains("\(root)/folder-00010/file.txt"))
    }

    @Test func fileEventsClassifyExactAndSubtreeRefreshes() {
        let fileEvent = FileSystemEvent(
            path: "/tmp/openfind-index/a/file.txt",
            eventID: 1,
            flags: UInt32(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile),
            receivedAt: .now,
            requiresFullRescan: false
        )
        let directoryEvent = FileSystemEvent(
            path: "/tmp/openfind-index/a/subdir",
            eventID: 2,
            flags: UInt32(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsDir),
            receivedAt: .now,
            requiresFullRescan: false
        )
        let createdDirectoryEvent = FileSystemEvent(
            path: "/tmp/openfind-index/a/new-subdir",
            eventID: 3,
            flags: UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsDir),
            receivedAt: .now,
            requiresFullRescan: false
        )
        let renamedFileEvent = FileSystemEvent(
            path: "/tmp/openfind-index/a/renamed.txt",
            eventID: 4,
            flags: UInt32(kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemIsFile),
            receivedAt: .now,
            requiresFullRescan: false
        )
        let renamedDirectoryEvent = FileSystemEvent(
            path: "/tmp/openfind-index/a/renamed-directory",
            eventID: 5,
            flags: UInt32(kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemIsDir),
            receivedAt: .now,
            requiresFullRescan: false
        )
        let directoryPermissionEvent = FileSystemEvent(
            path: "/tmp/openfind-index/a/permission-changed",
            eventID: 6,
            flags: UInt32(kFSEventStreamEventFlagItemInodeMetaMod | kFSEventStreamEventFlagItemIsDir),
            receivedAt: .now,
            requiresFullRescan: false
        )

        #expect(fileEvent.indexRefresh == .exact("/tmp/openfind-index/a/file.txt"))
        #expect(directoryEvent.indexRefresh == .exact("/tmp/openfind-index/a/subdir"))
        #expect(createdDirectoryEvent.indexRefresh == .subtree("/tmp/openfind-index/a/new-subdir"))
        #expect(renamedFileEvent.indexRefresh == .exact("/tmp/openfind-index/a/renamed.txt"))
        #expect(renamedDirectoryEvent.indexRefresh == .subtree("/tmp/openfind-index/a/renamed-directory"))
        #expect(directoryPermissionEvent.indexRefresh == .directoryMetadata("/tmp/openfind-index/a/permission-changed"))
    }

    @Test func directoryMetadataRefreshAvoidsUnchangedReadableSubtreeScans() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenFind-DirectoryMetadata-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let path = SearchPath.canonicalAliasPath(root.path(percentEncoded: false))
        #expect(SearchIndexStore.resolvedDirectoryMetadataRefresh(
            path: path,
            knownUnavailablePaths: []
        ) == .exact(path))
        #expect(SearchIndexStore.resolvedDirectoryMetadataRefresh(
            path: path,
            knownUnavailablePaths: [path + "/previously-unavailable"]
        ) == .subtree(path))

        try FileManager.default.removeItem(at: root)
        #expect(SearchIndexStore.resolvedDirectoryMetadataRefresh(
            path: path,
            knownUnavailablePaths: []
        ) == .subtree(path))
    }

    @Test func fullHistoryDocumentIDTransitionsAreNotFilesystemRefreshPaths() {
        let syntheticPath = "/.docid/16777233/changed/2406971/src=306963189,dst=306994397"
        let event = FileSystemEvent(
            path: syntheticPath,
            eventID: 6,
            flags: UInt32(kFSEventStreamEventFlagItemModified),
            receivedAt: .now,
            requiresFullRescan: false
        )

        #expect(FileSystemEvent.isSyntheticDocumentIDPath(syntheticPath))
        #expect(event.indexRefresh == nil)
        #expect(!FileSystemEvent.isSyntheticDocumentIDPath("/.docid/user-created.txt"))
    }

    @Test func fileEventWatcherRequestsDurableHistoryWithExtendedPaths() {
        let flags = FileSystemEventWatcher.creationFlags(fileEvents: true)

        #expect((flags & UInt32(kFSEventStreamCreateFlagUseCFTypes)) != 0)
        #expect((flags & UInt32(kFSEventStreamCreateFlagUseExtendedData)) != 0)
        #expect((flags & UInt32(kFSEventStreamCreateFlagFullHistory)) != 0)
        #expect((flags & UInt32(kFSEventStreamCreateFlagFileEvents)) != 0)
    }

    @Test func fileEventWatcherExtractsLegacyAndExtendedPaths() {
        let extended: NSDictionary = ["path": "/tmp/extended.txt"]

        #expect(FileSystemEventWatcher.eventPath(from: extended, isHistoryDone: false) == "/tmp/extended.txt")
        #expect(FileSystemEventWatcher.eventPath(from: "/tmp/legacy.txt", isHistoryDone: false) == "/tmp/legacy.txt")
        #expect(FileSystemEventWatcher.eventPath(from: extended, isHistoryDone: true) == nil)
    }

    @Test func freshBuildDropsOnlyFullHistoryOverlapAtOrBeforeItsBaseline() {
        func event(id: UInt64) -> FileSystemEvent {
            FileSystemEvent(
                path: "/tmp/event-\(id)",
                eventID: id,
                flags: UInt32(kFSEventStreamEventFlagItemModified),
                receivedAt: .now,
                requiresFullRescan: false
            )
        }

        let events = [event(id: 0), event(id: 99), event(id: 100), event(id: 101)]
        let filtered = SearchIndexStore.eventsAfterFreshBuildBaseline(events, ignoringThrough: 100)

        #expect(filtered.map(\.eventID) == [0, 101])
        #expect(SearchIndexStore.eventsAfterFreshBuildBaseline(events, ignoringThrough: nil).count == 4)
    }

    @Test func eventPrefixLookupHonorsDirectoryBoundaries() {
        let prefixes = ["/Users/example/Project", "/private/tmp"].sorted()

        #expect(SearchIndexBuilder.isPath("/Users/example/Project/file.txt", coveredBySortedPrefixes: prefixes))
        #expect(SearchIndexBuilder.isPath("/private/tmp", coveredBySortedPrefixes: prefixes))
        #expect(!SearchIndexBuilder.isPath("/Users/example/Projection/file.txt", coveredBySortedPrefixes: prefixes))
        #expect(!SearchIndexBuilder.isPath("/Users/example/Other/file.txt", coveredBySortedPrefixes: prefixes))
    }

    @Test func eventPrefixLookupIsNotShadowedBySiblingNames() {
        let prefixes = [
            "/Users/example/Project",
            "/Users/example/Project-Archive",
            "/Users/example/Project.backup",
        ].sorted()

        #expect(SearchIndexBuilder.isPath("/Users/example/Project/file.txt", coveredBySortedPrefixes: prefixes))
        #expect(SearchIndexBuilder.isPath("/Users/example/Project/Sources/main.swift", coveredBySortedPrefixes: prefixes))
        #expect(!SearchIndexBuilder.isPath("/Users/example/Projection/file.txt", coveredBySortedPrefixes: prefixes))
    }

    @Test func eventReplacementOverlayUpdatesOnlyTheChangedSubtree() async throws {
        let root = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let changedDirectory = root.appendingPathComponent("changed", isDirectory: true)
        let stableDirectory = root.appendingPathComponent("stable", isDirectory: true)
        try FileManager.default.createDirectory(at: changedDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stableDirectory, withIntermediateDirectories: true)
        let oldFile = changedDirectory.appendingPathComponent("old-result.txt")
        try writeFile(at: oldFile)
        try writeFile(at: stableDirectory.appendingPathComponent("stable-result.txt"))

        let signature = SearchIndexSignature(scopes: [root], deepIndex: true)
        let baseNodes = await SearchIndexBuilder.build(signature: signature)

        try FileManager.default.removeItem(at: oldFile)
        try writeFile(at: changedDirectory.appendingPathComponent("new-result.txt"))
        let replacement = try #require(await SearchIndexBuilder.scanReplacements(
            paths: [changedDirectory.path],
            signature: signature
        ).first)
        let composite = SearchIndex(
            signature: signature,
            nodes: baseNodes,
            replacements: [replacement]
        )

        func resultNames(for queryText: String) throws -> [String] {
            var options = SearchOptions()
            options.query = queryText
            options.target = .name
            let query = try SearchQueryPlan.parse(queryText).compile(options: options)
            return composite.nameMatches(query: query, options: options).map(\.name)
        }

        #expect(try resultNames(for: "old-result").isEmpty)
        #expect(try resultNames(for: "new-result") == ["new-result.txt"])
        #expect(try resultNames(for: "stable-result") == ["stable-result.txt"])
    }

    @Test func exactEventOverlayUpdatesOneNodeWithoutHidingSiblings() async throws {
        let root = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("exact", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let oldFile = directory.appendingPathComponent("old-exact-result.txt")
        let stableFile = directory.appendingPathComponent("stable-exact-result.txt")
        try writeFile(at: oldFile)
        try writeFile(at: stableFile)

        let signature = SearchIndexSignature(scopes: [root], deepIndex: true)
        let baseNodes = await SearchIndexBuilder.build(signature: signature)

        try FileManager.default.removeItem(at: oldFile)
        let newFile = directory.appendingPathComponent("new-exact-result.txt")
        try writeFile(at: newFile)
        let exactReplacements = SearchIndexBuilder.scanExactReplacements(
            paths: [directory.path, oldFile.path, newFile.path],
            signature: signature
        )
        let composite = SearchIndex(
            signature: signature,
            nodes: baseNodes,
            exactReplacements: exactReplacements
        )

        func resultNames(for queryText: String) throws -> [String] {
            var options = SearchOptions()
            options.query = queryText
            options.target = .name
            let query = try SearchQueryPlan.parse(queryText).compile(options: options)
            return composite.nameMatches(query: query, options: options).map(\.name)
        }

        #expect(try resultNames(for: "old-exact-result").isEmpty)
        #expect(try resultNames(for: "new-exact-result") == ["new-exact-result.txt"])
        #expect(try resultNames(for: "stable-exact-result") == ["stable-exact-result.txt"])
    }

    @Test func exactEventMetadataKeepsSearchFilterFields() throws {
        let root = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageDirectory = root.appendingPathComponent("Example.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
        let file = packageDirectory.appendingPathComponent(".payload.bin")
        let contents = Data(repeating: 0x2A, count: 4_321)
        try contents.write(to: file)
        let modified = Date(timeIntervalSinceReferenceDate: 600_000_000)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)

        let signature = SearchIndexSignature(scopes: [root], deepIndex: true)
        let replacements = SearchIndexBuilder.scanExactReplacements(
            paths: [packageDirectory.path, file.path],
            signature: signature
        )
        let directoryNode = try #require(replacements.first { $0.path == packageDirectory.path }?.node)
        let fileNode = try #require(replacements.first { $0.path == file.path }?.node)

        #expect(directoryNode.isDirectory)
        #expect(!fileNode.isDirectory)
        #expect(fileNode.size == Int64(contents.count))
        #expect(abs(fileNode.modifiedTime - modified.timeIntervalSinceReferenceDate) < 1)
        #expect(fileNode.creationTime > 0)
        #expect(fileNode.isHiddenScope)
        #expect(fileNode.isPackageDescendant)
    }

    @Test func nestedSubtreeReplacementOverridesOlderParentSnapshot() async throws {
        let root = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("parent", isDirectory: true)
        let child = parent.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try writeFile(at: parent.appendingPathComponent("stable-parent-result.txt"))
        let oldChildFile = child.appendingPathComponent("old-child-result.txt")
        try writeFile(at: oldChildFile)

        let signature = SearchIndexSignature(scopes: [root], deepIndex: true)
        let baseNodes = await SearchIndexBuilder.build(signature: signature)
        let parentReplacement = try #require(await SearchIndexBuilder.scanReplacements(
            paths: [parent.path],
            signature: signature
        ).first)

        try FileManager.default.removeItem(at: oldChildFile)
        try writeFile(at: child.appendingPathComponent("new-child-result.txt"))
        let childReplacement = try #require(await SearchIndexBuilder.scanReplacements(
            paths: [child.path],
            signature: signature
        ).first)
        let composite = SearchIndex(
            signature: signature,
            nodes: baseNodes,
            replacements: [parentReplacement, childReplacement]
        )

        func resultNames(for queryText: String) throws -> [String] {
            var options = SearchOptions()
            options.query = queryText
            options.target = .name
            let query = try SearchQueryPlan.parse(queryText).compile(options: options)
            return composite.nameMatches(query: query, options: options).map(\.name)
        }

        #expect(try resultNames(for: "old-child-result").isEmpty)
        #expect(try resultNames(for: "new-child-result") == ["new-child-result.txt"])
        #expect(try resultNames(for: "stable-parent-result") == ["stable-parent-result.txt"])
    }

    @Test func incompleteSubtreeReplacementPreservesUnscannedBaseDescendants() throws {
        let scope = "/tmp/openfind-preserved-scope"
        let changed = "\(scope)/changed"
        let unreadable = "\(changed)/temporarily-unreadable"
        let signature = SearchIndexSignature(scopes: [URL(fileURLWithPath: scope)], deepIndex: true)
        let baseNodes = SearchIndexBuilder.assembleIndexedNodes(from: [
            tempNode(path: scope, isDirectory: true),
            tempNode(path: changed, isDirectory: true),
            tempNode(path: unreadable, isDirectory: true),
            tempNode(path: "\(unreadable)/preserved-result.txt"),
            tempNode(path: "\(changed)/removed-result.txt"),
        ])
        let replacement = SearchIndexReplacement(
            rootPath: changed,
            nodes: [
                tempNode(path: changed, isDirectory: true),
                tempNode(path: "\(changed)/new-result.txt"),
            ],
            preservedBaseRoots: [unreadable]
        )
        let composite = SearchIndex(
            signature: signature,
            nodes: baseNodes,
            replacements: [replacement]
        )

        func resultNames(for queryText: String) throws -> [String] {
            var options = SearchOptions()
            options.query = queryText
            options.target = .name
            let query = try SearchQueryPlan.parse(queryText).compile(options: options)
            return composite.nameMatches(query: query, options: options).map(\.name)
        }

        #expect(try resultNames(for: "preserved-result") == ["preserved-result.txt"])
        #expect(try resultNames(for: "removed-result").isEmpty)
        #expect(try resultNames(for: "new-result") == ["new-result.txt"])
    }

    @Test func incompleteOverlayValidatesOnlyItsPreservedRoots() {
        let scope = "/tmp/openfind-scoped-validation"
        let changed = "\(scope)/changed"
        let unavailable = "\(changed)/temporarily-unavailable"
        let stable = "\(scope)/stable"
        let signature = SearchIndexSignature(
            scopes: [URL(fileURLWithPath: scope)],
            deepIndex: true
        )
        let base = SearchIndex(
            signature: signature,
            nodes: SearchIndexBuilder.assembleIndexedNodes(from: [
                tempNode(path: scope, isDirectory: true),
                tempNode(path: changed, isDirectory: true),
                tempNode(path: unavailable, isDirectory: true),
                tempNode(path: "\(unavailable)/possibly-stale.txt"),
                tempNode(path: stable, isDirectory: true),
                tempNode(path: "\(stable)/known-fresh.txt"),
            ]),
            pathsAreFresh: true
        )
        let replacement = SearchIndexReplacement(
            rootPath: changed,
            nodes: [tempNode(path: changed, isDirectory: true)],
            preservedBaseRoots: [unavailable]
        )
        let composite = base.overlaying(
            replacements: [replacement],
            exactReplacements: []
        )

        #expect(composite.requiresAnyExistenceValidation)
        #expect(composite.requiresExistenceValidation(for: "\(unavailable)/possibly-stale.txt"))
        #expect(!composite.requiresExistenceValidation(for: "\(stable)/known-fresh.txt"))
    }

    @Test func manyScopedValidationRootsHonorDirectoryBoundaries() {
        let signature = SearchIndexSignature(
            scopes: [URL(fileURLWithPath: "/")],
            deepIndex: true
        )
        let roots = (0..<12).map { "/Users/example/Project-\($0)" }
            + ["/Users/example/Project"]
        let index = SearchIndex(
            signature: signature,
            nodes: [],
            pathsAreFresh: true
        ).withExistenceValidationRoots(roots)

        #expect(index.requiresExistenceValidation(for: "/Users/example/Project/file.txt"))
        #expect(index.requiresExistenceValidation(for: "/Users/example/Project-7/file.txt"))
        #expect(!index.requiresExistenceValidation(for: "/Users/example/Projection/file.txt"))
        #expect(!index.requiresExistenceValidation(for: "/Users/example/Other/file.txt"))
    }

    @Test func nestedReplacementStillOverridesAParentPreservedPrefix() throws {
        let scope = "/tmp/openfind-nested-preserved-scope"
        let parent = "\(scope)/parent"
        let child = "\(parent)/child"
        let signature = SearchIndexSignature(scopes: [URL(fileURLWithPath: scope)], deepIndex: true)
        let baseNodes = SearchIndexBuilder.assembleIndexedNodes(from: [
            tempNode(path: scope, isDirectory: true),
            tempNode(path: parent, isDirectory: true),
            tempNode(path: child, isDirectory: true),
            tempNode(path: "\(child)/old-nested-result.txt"),
        ])
        let parentReplacement = SearchIndexReplacement(
            rootPath: parent,
            nodes: [tempNode(path: parent, isDirectory: true)],
            preservedBaseRoots: [child]
        )
        let childReplacement = SearchIndexReplacement(
            rootPath: child,
            nodes: [
                tempNode(path: child, isDirectory: true),
                tempNode(path: "\(child)/new-nested-result.txt"),
            ]
        )
        let composite = SearchIndex(
            signature: signature,
            nodes: baseNodes,
            replacements: [parentReplacement, childReplacement]
        )

        var options = SearchOptions()
        options.target = .name
        options.query = "nested-result"
        let query = try SearchQueryPlan.parse(options.query).compile(options: options)

        #expect(composite.nameMatches(query: query, options: options).map(\.name) == ["new-nested-result.txt"])
    }

    @Test func nestedPartialReplacementFallsBackToTheNewerParentSnapshot() throws {
        let scope = "/tmp/openfind-nested-fallback-scope"
        let parent = "\(scope)/parent"
        let child = "\(parent)/child"
        let unreadable = "\(child)/temporarily-unreadable"
        let signature = SearchIndexSignature(scopes: [URL(fileURLWithPath: scope)], deepIndex: true)
        let baseNodes = SearchIndexBuilder.assembleIndexedNodes(from: [
            tempNode(path: scope, isDirectory: true),
            tempNode(path: parent, isDirectory: true),
            tempNode(path: child, isDirectory: true),
            tempNode(path: unreadable, isDirectory: true),
            tempNode(path: "\(unreadable)/removed-by-parent.txt"),
        ])
        let parentReplacement = SearchIndexReplacement(
            rootPath: parent,
            nodes: [
                tempNode(path: parent, isDirectory: true),
                tempNode(path: child, isDirectory: true),
                tempNode(path: unreadable, isDirectory: true),
                tempNode(path: "\(unreadable)/fresher-parent-result.txt"),
            ]
        )
        let childReplacement = SearchIndexReplacement(
            rootPath: child,
            nodes: [
                tempNode(path: child, isDirectory: true),
                tempNode(path: "\(child)/new-child-result.txt"),
            ],
            preservedBaseRoots: [unreadable]
        )
        let composite = SearchIndex(
            signature: signature,
            nodes: baseNodes,
            replacements: [parentReplacement, childReplacement]
        )

        func resultNames(for queryText: String) throws -> [String] {
            var options = SearchOptions()
            options.query = queryText
            options.target = .name
            let query = try SearchQueryPlan.parse(queryText).compile(options: options)
            return composite.nameMatches(query: query, options: options).map(\.name)
        }

        #expect(try resultNames(for: "fresher-parent-result") == ["fresher-parent-result.txt"])
        #expect(try resultNames(for: "removed-by-parent").isEmpty)
        #expect(try resultNames(for: "new-child-result") == ["new-child-result.txt"])
    }

    @Test func exactOverlayCompactionSelectsOnlyDenseDeepParents() {
        let signature = SearchIndexSignature(
            scopes: [URL(fileURLWithPath: "/")],
            deepIndex: true
        )
        let denseParent = "/Users/test/Library/Application Support/FileProvider/id/wharf/delete"
        let densePaths = (0..<80).map { "\(denseParent)/event-\($0)" }
        let sparsePaths = (0..<20).map { "/private/tmp/sparse-\($0)/event" }

        let roots = SearchIndexBuilder.exactOverlayCompactionRoots(
            paths: densePaths + sparsePaths,
            signature: signature,
            triggerCount: 50,
            targetCount: 20,
            minimumGroupSize: 64,
            maximumRoots: 4
        )

        #expect(roots == [denseParent])
    }

    @Test func exactOverlayCompactionNeverPromotesAShallowHomeRoot() {
        let signature = SearchIndexSignature(
            scopes: [URL(fileURLWithPath: "/")],
            deepIndex: true
        )
        let paths = (0..<100).map { "/Users/tester/direct-event-\($0)" }

        let roots = SearchIndexBuilder.exactOverlayCompactionRoots(
            paths: paths,
            signature: signature,
            triggerCount: 50,
            targetCount: 20,
            minimumGroupSize: 64,
            maximumRoots: 4
        )

        #expect(roots.isEmpty)
    }

    @Test func querySyntaxFiltersIndexedResults() async throws {
        let root = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let archive = root.appendingPathComponent("Archive")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try writeFile(at: root.appendingPathComponent("report.pdf"), content: "short")
        try writeFile(at: root.appendingPathComponent("report.txt"), content: "short")
        try writeFile(at: root.appendingPathComponent("draft_report.pdf"), content: "short")
        try writeFile(at: archive.appendingPathComponent("archive_report.pdf"), content: "short")
        try writeFile(at: root.appendingPathComponent("large.bin"), content: String(repeating: "x", count: 256))

        var options = SearchOptions()
        options.target = .name

        // Relevance ranking puts the stem-exact hit before the word-boundary hit.
        options.query = "report ext:pdf !draft"
        var results = await collect(scopes: [root], options: options)
        #expect(results.map(\.name) == ["report.pdf", "archive_report.pdf"])

        options.query = "path:Archive"
        results = await collect(scopes: [root], options: options)
        #expect(Set(results.map(\.name)) == Set(["Archive", "archive_report.pdf"]))

        options.query = "size:>100b"
        results = await collect(scopes: [root], options: options)
        #expect(results.map(\.name) == ["large.bin"])

        options.query = "folder:Archive"
        results = await collect(scopes: [root], options: options)
        #expect(results.map(\.name) == ["Archive"])
    }

    @Test func cardinalStyleFiltersWorkInDefaultMode() async throws {
        let root = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeFile(at: root.appendingPathComponent("briefing.pdf"), content: "deck")
        try writeFile(at: root.appendingPathComponent("briefing.txt"), content: "notes")
        try writeFile(at: root.appendingPathComponent("travel.jpg"), content: "image")
        try writeFile(at: root.appendingPathComponent("travel.png"), content: "image")
        try writeFile(at: root.appendingPathComponent("travel.gif"), content: "image")
        try writeFile(at: root.appendingPathComponent("openfind.swift"), content: "code")
        try writeFile(at: root.appendingPathComponent("invoice.docx"), content: "doc")
        try writeFile(at: root.appendingPathComponent("empty.txt"), content: "")
        try writeFile(at: root.appendingPathComponent("tiny.txt"), content: "x")

        var options = SearchOptions()
        options.target = .name

        options.query = "*.pdf briefing"
        var results = await collect(scopes: [root], options: options)
        #expect(results.map(\.name) == ["briefing.pdf"])

        options.query = "ext:png;jpg travel"
        results = await collect(scopes: [root], options: options)
        #expect(Set(results.map(\.name)) == Set(["travel.jpg", "travel.png"]))

        options.query = "type:code openfind"
        results = await collect(scopes: [root], options: options)
        #expect(results.map(\.name) == ["openfind.swift"])

        options.query = "doc:invoice"
        results = await collect(scopes: [root], options: options)
        #expect(results.map(\.name) == ["invoice.docx"])

        options.query = "size:empty"
        results = await collect(scopes: [root], options: options)
        #expect(results.map(\.name) == ["empty.txt"])

        options.query = "size:tiny"
        results = await collect(scopes: [root], options: options)
        #expect(Set(results.map(\.name)).contains("tiny.txt"))
        #expect(!Set(results.map(\.name)).contains("empty.txt"))

        options.query = "size:!=0b"
        results = await collect(scopes: [root], options: options)
        #expect(Set(results.map(\.name)).contains("tiny.txt"))
        #expect(!Set(results.map(\.name)).contains("empty.txt"))
    }

    @Test func booleanAndPathSyntaxMatchesCardinalStyle() async throws {
        let root = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let reports2025 = root.appendingPathComponent("Docs/2025", isDirectory: true)
        let reports2024 = root.appendingPathComponent("Docs/2024", isDirectory: true)
        let appSupport = root.appendingPathComponent("Library/Application Support", isDirectory: true)
        let nestedSource = root.appendingPathComponent("src/OpenFind/Engine", isDirectory: true)
        try FileManager.default.createDirectory(at: reports2025, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: reports2024, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nestedSource, withIntermediateDirectories: true)

        try writeFile(at: reports2025.appendingPathComponent("report_summary.pdf"))
        try writeFile(at: reports2024.appendingPathComponent("report_draft.pdf"))
        try writeFile(at: reports2024.appendingPathComponent("summary_only.pdf"))
        try writeFile(at: appSupport.appendingPathComponent("openfind.conf"))
        try writeFile(at: nestedSource.appendingPathComponent("SearchQuery.swift"))

        var options = SearchOptions()
        options.target = .name

        options.query = "report summary|draft ext:pdf"
        var results = await collect(scopes: [root], options: options)
        #expect(Set(results.map(\.name)) == Set(["report_summary.pdf", "report_draft.pdf"]))

        options.query = "report !draft ext:pdf"
        results = await collect(scopes: [root], options: options)
        #expect(results.map(\.name) == ["report_summary.pdf"])

        options.query = "<summary|draft> ext:pdf"
        results = await collect(scopes: [root], options: options)
        #expect(Set(results.map(\.name)) == Set(["report_summary.pdf", "report_draft.pdf", "summary_only.pdf"]))

        options.query = "report_*.pdf"
        results = await collect(scopes: [root], options: options)
        #expect(Set(results.map(\.name)) == Set(["report_summary.pdf", "report_draft.pdf"]))

        options.query = "brary/Applicat"
        results = await collect(scopes: [root], options: options)
        #expect(Set(results.map(\.name)).contains("openfind.conf"))

        options.query = "src/**/SearchQuery.swift"
        results = await collect(scopes: [root], options: options)
        #expect(results.map(\.name) == ["SearchQuery.swift"])

        options.query = "/SearchQuery.swift/"
        results = await collect(scopes: [root], options: options)
        #expect(results.map(\.name) == ["SearchQuery.swift"])
    }

    @Test func nameFilterRejectsObviousNonMatchesBeforePathResolution() throws {
        var options = SearchOptions()
        options.target = .name

        options.query = "puremac"
        var query = try SearchQueryPlan.parse(options.query).compile(options: options)
        #expect(!query.matchesNameFilter("unrelated.txt", matchesPinyin: query.matchesPinyin))
        #expect(query.matchesNameFilter("PureMac.app", matchesPinyin: query.matchesPinyin))

        options.query = "report summary|draft ext:pdf"
        query = try SearchQueryPlan.parse(options.query).compile(options: options)
        #expect(!query.matchesNameFilter("notes.pdf", matchesPinyin: query.matchesPinyin))
        #expect(!query.matchesNameFilter("report_final.pdf", matchesPinyin: query.matchesPinyin))
        #expect(query.matchesNameFilter("report_draft.pdf", matchesPinyin: query.matchesPinyin))

        options.query = "src/**/SearchQuery.swift"
        query = try SearchQueryPlan.parse(options.query).compile(options: options)
        #expect(query.matchesNameFilter("unrelated.txt", matchesPinyin: query.matchesPinyin))
    }

    @Test func plainNameSearchDoesNotMatchAncestorPath() async throws {
        let root = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let project = root.appendingPathComponent("ProjectName", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try writeFile(at: project.appendingPathComponent("unrelated.txt"))

        var options = SearchOptions()
        options.target = .name
        options.query = "ProjectName"

        var results = await collect(scopes: [root], options: options)
        #expect(results.map(\.name) == ["ProjectName"])

        options.query = "ProjectName/unrelated"
        results = await collect(scopes: [root], options: options)
        #expect(results.map(\.name) == ["unrelated.txt"])

        options.query = "path:ProjectName"
        results = await collect(scopes: [root], options: options)
        #expect(Set(results.map(\.name)) == Set(["ProjectName", "unrelated.txt"]))
    }

    @Test func contentFilterRunsEvenWhenTargetIsName() async throws {
        let root = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeFile(at: root.appendingPathComponent("budget.txt"), content: "q3 actuals")
        try writeFile(at: root.appendingPathComponent("notes.txt"), content: "q3 actuals")
        try writeFile(at: root.appendingPathComponent("budget.md"), content: "q3 actuals")
        try writeFile(at: root.appendingPathComponent("budget_empty.txt"), content: "nothing")

        var options = SearchOptions()
        options.target = .name
        options.query = "budget ext:txt content:q3"

        let results = await collect(scopes: [root], options: options)
        #expect(results.map(\.name) == ["budget.txt"])
        #expect(results.first?.matchedContent == true)
    }

    @Test func booleanContentPredicatesEvaluatePerFile() async throws {
        let root = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeFile(at: root.appendingPathComponent("alpha.txt"), content: "red")
        try writeFile(at: root.appendingPathComponent("beta.txt"), content: "blue")
        try writeFile(at: root.appendingPathComponent("both.txt"), content: "red\nblue")
        try writeFile(at: root.appendingPathComponent("neither.txt"), content: "green")

        var options = SearchOptions()
        options.target = .name

        options.query = "content:red content:blue"
        var results = await collect(scopes: [root], options: options)
        #expect(results.map(\.name) == ["both.txt"])

        options.query = "content:red|content:blue"
        results = await collect(scopes: [root], options: options)
        #expect(Set(results.map(\.name)) == Set(["alpha.txt", "beta.txt", "both.txt"]))

        options.query = "!content:red ext:txt"
        results = await collect(scopes: [root], options: options)
        #expect(Set(results.map(\.name)) == Set(["beta.txt", "neither.txt"]))

        options.query = "alpha|content:blue"
        results = await collect(scopes: [root], options: options)
        #expect(Set(results.map(\.name)) == Set(["alpha.txt", "beta.txt", "both.txt"]))

        options.target = .content
        options.matchMode = .regex
        options.query = "r.d"
        results = await collect(scopes: [root], options: options)
        #expect(Set(results.map(\.name)) == Set(["alpha.txt", "both.txt"]))
    }

    @Test func cardinalScopeDateTagAndRegexFiltersWork() async throws {
        let root = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let scoped = root.appendingPathComponent("Scope", isDirectory: true)
        let nested = scoped.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let directFile = scoped.appendingPathComponent("direct.log")
        let nestedFile = nested.appendingPathComponent("nested.log")
        let taggedFile = root.appendingPathComponent("Report-2026.md")
        try writeFile(at: directFile, content: "direct")
        try writeFile(at: nestedFile, content: "nested")
        try writeFile(at: taggedFile, content: "tagged")
        try writeFile(at: root.appendingPathComponent("Report-old.md"), content: "old")

        let tagData = try PropertyListSerialization.data(
            fromPropertyList: ["ProjectA\n6", "Important\n6"],
            format: .binary,
            options: 0
        )
        let tagStatus = tagData.withUnsafeBytes { bytes in
            setxattr(
                taggedFile.path,
                "com.apple.metadata:_kMDItemUserTags",
                bytes.baseAddress,
                bytes.count,
                0,
                0
            )
        }
        #expect(tagStatus == 0)

        var options = SearchOptions()
        options.target = .name

        options.query = "parent:\(scoped.path) file:"
        var results = await collect(scopes: [root], options: options)
        #expect(results.map(\.name) == ["direct.log"])

        options.query = "in:\(scoped.path) ext:log"
        results = await collect(scopes: [root], options: options)
        #expect(Set(results.map(\.name)) == Set(["direct.log", "nested.log"]))

        options.query = "nosubfolders:\(scoped.path)"
        results = await collect(scopes: [root], options: options)
        #expect(Set(results.map(\.name)) == Set(["Scope", "direct.log"]))

        options.query = "tag:proj"
        results = await collect(scopes: [root], options: options)
        #expect(results.map(\.name) == ["Report-2026.md"])

        options.query = "regex:^Report-[0-9]{4}\\.md$"
        results = await collect(scopes: [root], options: options)
        #expect(results.map(\.name) == ["Report-2026.md"])
    }

    @Test func creationDateAndAngleGroupedComparisonWork() throws {
        let signature = SearchIndexSignature(scopes: [URL(fileURLWithPath: "/tmp")])
        let oldDate = try #require(DatePredicate.parse("2024-01-01").flatMap { predicate -> Date? in
            if case .comparison(_, let date) = predicate.kind { return date }
            return nil
        })
        let newDate = try #require(DatePredicate.parse("2026-01-01").flatMap { predicate -> Date? in
            if case .comparison(_, let date) = predicate.kind { return date }
            return nil
        })
        let nodes = [
            IndexedFileNode(
                name: "/tmp/old.txt", parentIndex: -1, isDirectory: false, size: 2,
                modifiedTime: oldDate.timeIntervalSinceReferenceDate,
                creationTime: oldDate.timeIntervalSinceReferenceDate,
                isHiddenScope: false, isPackageDescendant: false
            ),
            IndexedFileNode(
                name: "/tmp/new.txt", parentIndex: -1, isDirectory: false, size: 8,
                modifiedTime: newDate.timeIntervalSinceReferenceDate,
                creationTime: newDate.timeIntervalSinceReferenceDate,
                isHiddenScope: false, isPackageDescendant: false
            ),
        ]
        let index = SearchIndex(signature: signature, nodes: nodes)
        var options = SearchOptions()
        options.target = .name

        options.query = "dc:>=2025-01-01"
        var query = try SearchQueryPlan.parse(options.query).compile(options: options)
        #expect(index.nameMatches(query: query, options: options).map(\.name) == ["new.txt"])

        options.query = "<size:>4b|ext:md>"
        query = try SearchQueryPlan.parse(options.query).compile(options: options)
        #expect(index.nameMatches(query: query, options: options).map(\.name) == ["new.txt"])
    }

    @Test func quotedWildcardIsLiteral() async throws {
        let root = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeFile(at: root.appendingPathComponent("*.rs"))
        try writeFile(at: root.appendingPathComponent("main.rs"))

        var options = SearchOptions()
        options.target = .name
        options.query = "\"*.rs\""

        let results = await collect(scopes: [root], options: options)
        #expect(results.map(\.name) == ["*.rs"])
    }

    @Test func nameResultsRankByMatchQuality() async throws {
        let root = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeFile(at: root.appendingPathComponent("myreport.txt"))
        try writeFile(at: root.appendingPathComponent("draft_report.pdf"))
        try writeFile(at: root.appendingPathComponent("reports_2024.txt"))
        try writeFile(at: root.appendingPathComponent("report.pdf"))
        try writeFile(at: root.appendingPathComponent("report"))

        var options = SearchOptions()
        options.target = .name
        options.query = "report"

        let results = await collect(scopes: [root], options: options)
        #expect(results.map(\.name) == [
            "report",           // complete filename exact
            "report.pdf",       // stem exact
            "reports_2024.txt", // prefix
            "draft_report.pdf", // word boundary
            "myreport.txt",     // bare substring
        ])
    }

    @Test func indexedResolvedNodeRepresentationStaysCompact() {
        #expect(MemoryLayout<ResolvedNode>.stride <= 32)
    }

    @Test func normalizedPrefixMatchesContainmentSemantics() {
        #expect(SearchPath.hasNormalizedPrefix("/a/b/c", of: "/a/b"))
        #expect(SearchPath.hasNormalizedPrefix("/a/b", of: "/a/b"))
        #expect(!SearchPath.hasNormalizedPrefix("/a/bc", of: "/a/b"))
        #expect(!SearchPath.hasNormalizedPrefix("/a", of: "/a/b"))
        #expect(SearchPath.hasNormalizedPrefix("/a", of: "/"))
    }

    @Test func nestedScopesCollapseToMinimalAncestors() {
        let root = URL(fileURLWithPath: "/tmp/openfind-scope")
        let nested = root.appendingPathComponent("child/grandchild")
        let sibling = URL(fileURLWithPath: "/tmp/openfind-sibling")

        let signature = SearchIndexSignature(scopes: [nested, sibling, root, root])

        #expect(signature.scopes == [root.path, sibling.path])
    }

    @Test func dataVolumeScopeContainsFirmlinkAliases() {
        let signature = SearchIndexSignature(scopes: [URL(fileURLWithPath: "/System/Volumes/Data")])

        #expect(signature.contains(path: "/System/Volumes/Data/MobileSoftwareUpdate/restore.log"))
        #expect(signature.contains(path: "/Applications/Example.app"))
        #expect(signature.contains(path: "/Users/tester/Tools/SampleApp"))
        #expect(signature.contains(path: "/Library/Application Support"))
        #expect(!signature.contains(path: "/System/Library/CoreServices"))
    }

    @Test func dataVolumeFirmlinkPathsCanonicalizeForDeduplication() {
        #expect(SearchPath.canonicalAliasPath("/System/Volumes/Data/Users/tester/Tools/SampleApp") == "/Users/tester/Tools/SampleApp")
        #expect(SearchPath.canonicalAliasPath("/System/Volumes/Data/Applications/Example.app") == "/Applications/Example.app")
        #expect(SearchPath.canonicalAliasPath("/System/Volumes/Data/MobileSoftwareUpdate/restore.log") == "/System/Volumes/Data/MobileSoftwareUpdate/restore.log")
    }

    @Test func noFollowPathsCanonicalizeForDeduplication() {
        #expect(SearchPath.canonicalAliasPath("/.nofollow") == "/")
        #expect(SearchPath.canonicalAliasPath("/.nofollow/") == "/")
        #expect(SearchPath.canonicalAliasPath("/.nofollow/Applications/PureMac.app") == "/Applications/PureMac.app")
        #expect(SearchPath.canonicalAliasPath("/.nofollow/Users/tester/Documents/file.txt") == "/Users/tester/Documents/file.txt")
        #expect(SearchPath.canonicalAliasPath("/.nofollow-suffix/file.txt") == "/.nofollow-suffix/file.txt")
        #expect(SearchPath.defaultIgnoredPaths.contains("/.nofollow"))
        #expect(SearchPath.deepIndexIgnoredPaths.contains("/.nofollow"))
    }

    @Test func canonicalScannerAppendPreservesAliasSemantics() {
        #expect(SearchPath.appendingCanonicalComponent("Users", to: "/") == "/Users")
        #expect(SearchPath.appendingCanonicalComponent("var", to: "/private") == "/var")
        #expect(SearchPath.appendingCanonicalComponent("tester", to: "/Users") == "/Users/tester")
        #expect(SearchPath.appendingCanonicalComponent(
            "Users",
            to: "/System/Volumes/Data"
        ) == "/Users")
    }

    @Test func wholeMacUsesNoiseFilteringUnlessDeepIndexEnabled() {
        let normal = SearchIndexSignature(scopes: [URL(fileURLWithPath: "/")], deepIndex: false)
        let deep = SearchIndexSignature(scopes: [URL(fileURLWithPath: "/")], deepIndex: true)

        let normalIgnored = SearchIndexBuilder.effectiveIgnoredPaths(for: normal)
        #expect(!normalIgnored.contains("/Volumes"))
        #expect(normalIgnored.contains("/Volumes/.timemachine"))
        #expect(normalIgnored.contains(SearchPath.normalize("/private/var")))
        #expect(normalIgnored.contains("/private/var"))
        #expect(normalIgnored.contains("/private/tmp"))
        #expect(normalIgnored.contains("/dev"))
        #expect(normalIgnored.contains("/.nofollow"))
        #expect(!normalIgnored.contains(SearchPath.normalize("~/Library/CloudStorage")))

        let deepIgnored = SearchIndexBuilder.effectiveIgnoredPaths(for: deep)
        #expect(!deepIgnored.contains("/Volumes"))
        #expect(!deepIgnored.contains("/Volumes/.timemachine"))
        #expect(!deepIgnored.contains(SearchPath.normalize("/private/var")))
        #expect(deepIgnored.contains("/dev"))
        #expect(deepIgnored.contains("/.nofollow"))
        #expect(SearchIndexBuilder.collapseEventPaths(
            ["/dev/fd/3", "/Users/test/kept.txt"],
            signature: deep
        ) == ["/Users/test/kept.txt"])
    }

    @Test func wholeMacAvoidsPrivacyPromptsUntilFullDiskAccessOrExplicitScopeGrant() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        let noFullDiskAccess = SearchIndexSignature(
            scopes: [URL(fileURLWithPath: "/")],
            deepIndex: true,
            hasFullDiskAccess: false
        )

        let ignored = SearchIndexBuilder.effectiveIgnoredPaths(for: noFullDiskAccess)
        #expect(ignored.contains("/Volumes"))
        #expect(ignored.contains(SearchPath.normalize("\(home)/Desktop")))
        #expect(ignored.contains(SearchPath.normalize("\(home)/Documents")))
        #expect(ignored.contains(SearchPath.normalize("\(home)/Downloads")))
        #expect(ignored.contains(SearchPath.normalize("\(home)/Music")))
        #expect(ignored.contains(SearchPath.normalize("\(home)/Movies")))
        #expect(ignored.contains(SearchPath.normalize("\(home)/Pictures")))
        #expect(ignored.contains(SearchPath.normalize("\(home)/Library/Mail")))

        let lightweight = SearchIndexSignature(
            scopes: [URL(fileURLWithPath: "/")],
            deepIndex: false,
            hasFullDiskAccess: false
        )
        let lightweightIgnored = SearchIndexBuilder.effectiveIgnoredPaths(for: lightweight)
        #expect(lightweightIgnored.contains(SearchPath.normalize("\(home)/Desktop")))
        #expect(lightweightIgnored.contains(SearchPath.normalize("\(home)/Documents")))

        let desktopPath = SearchPath.normalize("\(home)/Desktop")
        let untrustedDesktop = SearchIndexSignature(
            scopes: [URL(fileURLWithPath: "\(home)/Desktop")],
            hasFullDiskAccess: false
        )
        let untrustedIgnored = SearchIndexBuilder.effectiveIgnoredPaths(for: untrustedDesktop)
        #expect(untrustedIgnored.contains(desktopPath))

        let explicitlyAuthorizedDesktop = SearchIndexSignature(
            scopes: [URL(fileURLWithPath: "\(home)/Desktop")],
            hasFullDiskAccess: false,
            authorizedScopePaths: [desktopPath]
        )
        let explicitlyAuthorizedIgnored = SearchIndexBuilder.effectiveIgnoredPaths(
            for: explicitlyAuthorizedDesktop
        )
        #expect(!explicitlyAuthorizedIgnored.contains(desktopPath))

        let fullDiskAccess = SearchIndexSignature(
            scopes: [URL(fileURLWithPath: "/")],
            deepIndex: true,
            hasFullDiskAccess: true
        )
        #expect(fullDiskAccess != noFullDiskAccess)
        let fullAccessIgnored = SearchIndexBuilder.effectiveIgnoredPaths(for: fullDiskAccess)
        #expect(!fullAccessIgnored.contains(SearchPath.normalize("\(home)/Downloads")))
    }

    @Test func searchResultsDeduplicateNoFollowAliasesToCanonicalPath() throws {
        let signature = SearchIndexSignature(scopes: [URL(fileURLWithPath: "/")])
        let modified = Date().timeIntervalSinceReferenceDate
        let duplicateNodes = [
            IndexedFileNode(
                name: "/.nofollow/Applications/PureMac.app",
                parentIndex: -1,
                isDirectory: true,
                size: 0,
                modifiedTime: modified,
                creationTime: modified,
                isHiddenScope: true,
                isPackageDescendant: false
            ),
            IndexedFileNode(
                name: "/Applications/PureMac.app",
                parentIndex: -1,
                isDirectory: true,
                size: 0,
                modifiedTime: modified,
                creationTime: modified,
                isHiddenScope: false,
                isPackageDescendant: false
            ),
        ]
        let index = SearchIndex(signature: signature, nodes: duplicateNodes)
        var options = SearchOptions()
        options.target = .name
        options.query = "puremac"
        options.includeHidden = true
        let query = try SearchQueryPlan.parse(options.query).compile(options: options)

        let results = index.nameMatches(query: query, options: options)

        #expect(results.count == 1)
        #expect(results[0].path == "/Applications/PureMac.app")
    }

    @Test func searchResultsDeduplicateDataVolumeFirmlinkAliases() throws {
        let signature = SearchIndexSignature(scopes: [URL(fileURLWithPath: "/System/Volumes/Data")])
        let modified = Date().timeIntervalSinceReferenceDate
        let duplicateNodes = [
            IndexedFileNode(
                name: "/System/Volumes/Data/Users/tester/Tools/SampleApp",
                parentIndex: -1,
                isDirectory: true,
                size: 0,
                modifiedTime: modified,
                creationTime: modified,
                isHiddenScope: false,
                isPackageDescendant: false
            ),
            IndexedFileNode(
                name: "/Users/tester/Tools/SampleApp",
                parentIndex: -1,
                isDirectory: true,
                size: 0,
                modifiedTime: modified,
                creationTime: modified,
                isHiddenScope: false,
                isPackageDescendant: false
            ),
        ]
        let index = SearchIndex(signature: signature, nodes: duplicateNodes)
        var options = SearchOptions()
        options.target = .name
        options.query = "sampleapp"
        let query = try SearchQueryPlan.parse(options.query).compile(options: options)

        let results = index.nameMatches(query: query, options: options)

        #expect(results.count == 1)
        #expect(SearchPath.canonicalAliasPath(results[0].path) == "/Users/tester/Tools/SampleApp")
    }

    @Test func uniqueNameIndexMatchesSerialSearchWithoutDroppingDuplicatesOrPinyin() throws {
        let root = "/tmp/openfind-name-index"
        let signature = SearchIndexSignature(scopes: [URL(fileURLWithPath: root)], deepIndex: true)
        let nodes = SearchIndexBuilder.assembleIndexedNodes(from: [
            tempNode(path: root, isDirectory: true),
            tempNode(path: "\(root)/a", isDirectory: true),
            tempNode(path: "\(root)/b", isDirectory: true),
            tempNode(path: "\(root)/a/report.txt"),
            tempNode(path: "\(root)/b/report.txt"),
            tempNode(path: "\(root)/b/notes.md"),
            tempNode(path: "\(root)/测试文件.txt"),
        ])
        let indexed = SearchIndex(signature: signature, nodes: nodes)
        let serial = SearchIndex(signature: signature, nodes: nodes, buildNameIndex: false)

        for rawQuery in ["report", "re", "a", "report OR ext:md", "cswj", "NOT report"] {
            var options = SearchOptions()
            options.target = .name
            options.query = rawQuery
            let query = try SearchQueryPlan.parse(rawQuery).compile(options: options)
            let indexedPaths = indexed.nameMatches(query: query, options: options).map(\.path)
            let serialPaths = serial.nameMatches(query: query, options: options).map(\.path)
            #expect(indexedPaths == serialPaths)
        }
    }

    @Test func largeReplacementNameIndexPreservesDuplicatesAndPinyinMatches() throws {
        let root = "/tmp/openfind-large-replacement-index"
        let signature = SearchIndexSignature(scopes: [URL(fileURLWithPath: root)], deepIndex: true)
        var replacementNodes = (0..<1_200).map { index in
            tempNode(path: "\(root)/folder-\(index)/noise-\(index).txt")
        }
        replacementNodes.append(tempNode(path: "\(root)/a/report.txt"))
        replacementNodes.append(tempNode(path: "\(root)/b/report.txt"))
        replacementNodes.append(tempNode(path: "\(root)/测试文件.txt"))
        let replacement = SearchIndexReplacement(rootPath: root, nodes: replacementNodes)
        let index = SearchIndex(
            signature: signature,
            nodes: [],
            replacements: [replacement]
        )

        func resultPaths(for rawQuery: String) throws -> [String] {
            var options = SearchOptions()
            options.target = .name
            options.query = rawQuery
            let query = try SearchQueryPlan.parse(rawQuery).compile(options: options)
            return index.nameMatches(query: query, options: options).map(\.path)
        }

        #expect(Set(try resultPaths(for: "report")) == [
            "\(root)/a/report.txt",
            "\(root)/b/report.txt",
        ])
        #expect(try resultPaths(for: "cswj") == ["\(root)/测试文件.txt"])
        #expect(try resultPaths(for: "测试") == ["\(root)/测试文件.txt"])
        #expect(try resultPaths(for: "definitely-not-present").isEmpty)
    }

    @Test func unavailablePathDiagnosticsExposeRealRetryRoots() async throws {
        let root = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let retryPath = root.appendingPathComponent("temporarily-unavailable").path
        let cacheURL = root.appendingPathComponent("diagnostic-index.bin")
        let store = SearchIndexStore(
            persistenceURL: cacheURL,
            buildOperation: { _ in
                SearchIndexBuildResult(nodes: [], unresolvedPaths: [retryPath])
            }
        )

        _ = await store.prepare(scopes: [root], hasFullDiskAccess: true)

        #expect(await store.unavailablePathDiagnostics() == [
            SearchPath.canonicalAliasPath(retryPath),
        ])
    }

    @Test func broadReplacementScansAllFirstLevelBranches() async throws {
        let root = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for branchIndex in 0..<16 {
            let branch = root.appendingPathComponent("branch-\(branchIndex)", isDirectory: true)
            try FileManager.default.createDirectory(at: branch, withIntermediateDirectories: true)
            for fileIndex in 0..<5 {
                try writeFile(at: branch.appendingPathComponent("result-\(branchIndex)-\(fileIndex).txt"))
            }
        }

        let signature = SearchIndexSignature(scopes: [root], deepIndex: true)
        let replacement = try #require(await SearchIndexBuilder.scanReplacements(
            paths: [root.path],
            signature: signature
        ).first)
        let paths = Set(replacement.nodes.map(\.path))

        #expect(paths.count == 97)
        #expect(paths.contains(root.path))
        #expect(paths.contains(root.appendingPathComponent("branch-15/result-15-4.txt").path))
        #expect(replacement.preservedBaseRoots.isEmpty)
    }

    @Test func completeParentReplacementSkipsRedundantNestedJournalRoots() async throws {
        let root = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try writeFile(at: child.appendingPathComponent("result.txt"))
        let signature = SearchIndexSignature(scopes: [root], deepIndex: true)

        let replacements = await SearchIndexBuilder.scanReplacements(
            paths: [root.path, child.path],
            signature: signature
        )

        #expect(replacements.map(\.rootPath) == [root.path])
        #expect(replacements[0].nodes.contains { $0.path == child.appendingPathComponent("result.txt").path })
    }

    @Test func incompleteParentReplacementRetriesNestedJournalRoots() async throws {
        let root = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try writeFile(at: child.appendingPathComponent("result.txt"))
        let signature = SearchIndexSignature(scopes: [root], deepIndex: true)

        let replacements = await SearchIndexBuilder.scanReplacements(
            paths: [root.path, child.path],
            signature: signature,
            maximumNodesPerRoot: 1
        )

        #expect(Set(replacements.map(\.rootPath)) == [root.path, child.path])
        #expect(replacements.first { $0.rootPath == root.path }?.preservedBaseRoots == [root.path])
        #expect(replacements.first { $0.rootPath == child.path }?.preservedBaseRoots == [child.path])
    }

    @Test func scanFailuresRetryOnlyExistingNonPermissionPaths() throws {
        let root = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let permissionError = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        let ioError = NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
        let missingPath = root.appendingPathComponent("already-gone").path

        #expect(!SearchIndexBuilder.shouldRetryScanFailure(permissionError, path: root.path))
        #expect(!SearchIndexBuilder.shouldRetryScanFailure(ioError, path: missingPath))
        #expect(SearchIndexBuilder.shouldRetryScanFailure(ioError, path: root.path))
    }

    @Test func modifiedDateFilterMatchesIsoDay() async throws {
        let root = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let oldFile = root.appendingPathComponent("old.txt")
        let newFile = root.appendingPathComponent("new.txt")
        try writeFile(at: oldFile)
        try writeFile(at: newFile)

        let oldDate = try #require(DatePredicate.parse("2024-01-02").flatMap { predicate -> Date? in
            if case .comparison(_, let date) = predicate.kind { return date }
            return nil
        })
        let newDate = try #require(DatePredicate.parse("2025-02-03").flatMap { predicate -> Date? in
            if case .comparison(_, let date) = predicate.kind { return date }
            return nil
        })
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: oldFile.path)
        try FileManager.default.setAttributes([.modificationDate: newDate], ofItemAtPath: newFile.path)

        var options = SearchOptions()
        options.target = .name
        options.query = "dm:2025-02-03"

        let results = await collect(scopes: [root], options: options)
        #expect(results.map(\.name) == ["new.txt"])
    }

    @Test func indexScaleRegressionKeepsExpectedItemCountAndUniqueness() async throws {
        let root = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let folderCount = 40
        let filesPerFolder = 30
        for folderIndex in 0..<folderCount {
            let folder = root.appendingPathComponent("folder-\(folderIndex)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for fileIndex in 0..<filesPerFolder {
                try writeFile(at: folder.appendingPathComponent("bench-\(folderIndex)-\(fileIndex).txt"))
            }
        }

        let signature = SearchIndexSignature(scopes: [root])
        let started = ContinuousClock.now
        let nodes = await SearchIndexBuilder.build(signature: signature)
        let elapsed = ContinuousClock.now - started
        let index = SearchIndex(signature: signature, nodes: nodes)
        let paths = (0..<index.nodes.count).map { index.path(for: $0) }

        #expect(index.stats.indexedFiles == folderCount * filesPerFolder)
        #expect(index.stats.indexedDirectories == folderCount + 1)
        #expect(Set(paths).count == paths.count)
        #expect(elapsed < .seconds(20))
    }

    @Test func broadFreshNameSearchKeepsTailPathsDeferred() throws {
        let matchCount = 100_100
        var nodes: [IndexedFileNode] = [
            IndexedFileNode(
                name: "/", parentIndex: -1, isDirectory: true, size: 0,
                modifiedTime: 0, creationTime: 0,
                isHiddenScope: false, isPackageDescendant: false
            ),
        ]
        nodes.reserveCapacity(matchCount + 1)
        for index in 0..<matchCount {
            nodes.append(IndexedFileNode(
                name: "a-result-\(index).txt", parentIndex: 0,
                isDirectory: false, size: 0,
                modifiedTime: 0, creationTime: 0,
                isHiddenScope: false, isPackageDescendant: false
            ))
        }

        var options = SearchOptions()
        options.query = "a"
        options.target = .name
        let query = try SearchQueryPlan.parse(options.query).compile(options: options)
        let index = SearchIndex(
            signature: SearchIndexSignature(scopes: [URL(fileURLWithPath: "/")]),
            nodes: nodes,
            pathsAreFresh: true
        )

        let matches = index.nameMatches(query: query, options: options)

        #expect(matches.count == matchCount)
        #expect(matches.allSatisfy { $0.isPathDeferred })
        #expect(matches[matchCount / 2].path == "/a-result-\(matchCount / 2).txt")

        let eventInvalidatedMatches = index
            .withPathsAreFresh(false)
            .nameMatches(query: query, options: options)
        #expect(eventInvalidatedMatches.count == matchCount)
        #expect(eventInvalidatedMatches.allSatisfy { $0.isPathDeferred })
    }

    @Test func simpleSubstringFastScoreMatchesCompleteQueryAndRankingSemantics() throws {
        let names = [
            "a", "A", "a.txt", "alpha", "beta-a", "beta_a", "betaA",
            "no-match", "éa", "阿尔法", ".a", "foo."
        ]
        for caseSensitive in [false, true] {
            var options = SearchOptions()
            options.query = caseSensitive ? "A" : "a"
            options.target = .name
            options.caseSensitive = caseSensitive
            let query = try SearchQueryPlan.parse(options.query).compile(options: options)
            let needle = options.query.lowercased()

            for name in names {
                let score = query.simpleNameSubstringMatchScore(
                    name,
                    options: options,
                    matchesPinyin: query.matchesPinyin
                )
                let matches = query.matchesNameFilter(name, matchesPinyin: query.matchesPinyin)
                #expect((score != nil) == matches)
                if let score {
                    #expect(Int(score) == SearchRanking.score(name: name, needle: needle))
                }
            }
        }
    }

    @Test func broadLinearRankingMatchesReferenceHeadWithoutDroppingTail() throws {
        let matchCount = 100_100
        var nodes: [IndexedFileNode] = [
            IndexedFileNode(
                name: "/", parentIndex: -1, isDirectory: true, size: 0,
                modifiedTime: 0, creationTime: 0,
                isHiddenScope: false, isPackageDescendant: false
            ),
        ]
        var parents: [Int32] = [0]
        for depth in 1...5 {
            let parent = parents.last!
            nodes.append(IndexedFileNode(
                name: "level-\(depth)", parentIndex: parent, isDirectory: true, size: 0,
                modifiedTime: 0, creationTime: 0,
                isHiddenScope: false, isPackageDescendant: false
            ))
            parents.append(Int32(nodes.count - 1))
        }

        var resultIndices: [Int] = []
        resultIndices.reserveCapacity(matchCount)
        var scores: [UInt8] = []
        scores.reserveCapacity(matchCount)
        for ordinal in 0..<matchCount {
            let name: String
            switch ordinal % 4 {
            case 0: name = ordinal < 20 ? "a" : "a-prefix-\(ordinal)"
            case 1: name = "item-a-\(ordinal)"
            case 2: name = "data-\(ordinal)"
            default: name = "a-file-\(ordinal).txt"
            }
            let rank = SearchRanking.score(name: name, needle: "a")
            nodes.append(IndexedFileNode(
                name: name,
                parentIndex: parents[ordinal % parents.count],
                isDirectory: false, size: 0,
                modifiedTime: 0, creationTime: 0,
                isHiddenScope: false, isPackageDescendant: false
            ))
            resultIndices.append(nodes.count - 1)
            scores.append(UInt8(rank))
        }

        var options = SearchOptions()
        options.query = "a"
        options.target = .name
        let query = try SearchQueryPlan.parse(options.query).compile(options: options)
        let provider = SearchIndexPathProvider(nodes: nodes)
        let raw = resultIndices.map { ResolvedNode(index: $0, pathProvider: provider) }
        let expectedHead = raw.enumerated()
            .map { ordinal, node in
                (ordinal: ordinal, node: node, score: Int(scores[ordinal]), depth: node.pathDepth)
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score < rhs.score }
                if lhs.depth != rhs.depth { return lhs.depth < rhs.depth }
                return lhs.ordinal < rhs.ordinal
            }
            .prefix(2_000)
            .map { $0.node.identity }

        let ranked = SearchRanking.sortedByRelevance(
            raw,
            precomputedScores: scores,
            query: query,
            options: options
        )

        let index = SearchIndex(
            signature: SearchIndexSignature(scopes: [URL(fileURLWithPath: "/")]),
            nodes: nodes,
            pathsAreFresh: true
        )
        let compact = try #require(index.compactNameMatches(
            query: query,
            options: options
        ))
        let compactPaths = (0..<compact.count).map { compact.node(at: $0).path }

        #expect(ranked.count == raw.count)
        #expect(ranked.prefix(2_000).map(\.identity) == expectedHead)
        #expect(Set(ranked.map(\.identity)) == Set(raw.map(\.identity)))
        #expect(compact.count == matchCount)
        #expect(Array(compactPaths.prefix(2_000)) == ranked.prefix(2_000).map(\.path))
        #expect(Set(compactPaths) == Set(ranked.map(\.path)))
    }

    @Test func partialBuildLimitDoesNotReduceFinalCoverage() async throws {
        let root = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        for index in 0..<12 {
            try writeFile(at: root.appendingPathComponent("coverage-\(index).txt"))
        }

        let collector = ThreadSafeNodeCollector()
        let result = await SearchIndexBuilder.buildWithDiagnostics(
            signature: SearchIndexSignature(scopes: [root]),
            onBatch: { collector.append($0) },
            maximumPartialNodes: 3
        )

        #expect(collector.snapshot().count == 3)
        #expect(result.nodes.count == 13)
        let index = SearchIndex(signature: SearchIndexSignature(scopes: [root]), nodes: result.nodes)
        #expect(index.stats.indexedFiles == 12)
        #expect(index.stats.indexedDirectories == 1)
    }

    @Test func queryReadyBuilderMatchesCompleteNamePathAndVisibilityTopology() async throws {
        let root = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let hiddenDirectory = root.appendingPathComponent(".hidden", isDirectory: true)
        let packageDirectory = root.appendingPathComponent("Example.app", isDirectory: true)
        try FileManager.default.createDirectory(at: hiddenDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
        try writeFile(at: root.appendingPathComponent("visible.txt"), content: "visible metadata")
        try writeFile(at: hiddenDirectory.appendingPathComponent("inside-hidden.txt"))
        try writeFile(at: packageDirectory.appendingPathComponent("inside-package.txt"))

        let signature = SearchIndexSignature(
            scopes: [root],
            deepIndex: true,
            hasFullDiskAccess: true
        )
        let queryReadyResult = await SearchIndexBuilder.buildQueryReadyWithDiagnostics(
            signature: signature
        )
        let completeResult = await SearchIndexBuilder.buildWithDiagnostics(
            signature: signature,
            maximumPartialNodes: 0
        )
        let queryReady = SearchIndex(
            signature: signature,
            nodes: queryReadyResult.nodes,
            hasCompleteMetadata: false
        )
        let complete = SearchIndex(signature: signature, nodes: completeResult.nodes)
        let queryReadyByPath = Dictionary(uniqueKeysWithValues: queryReady.nodes.indices.map {
            (queryReady.path(for: $0), queryReady.nodes[$0])
        })
        let completeByPath = Dictionary(uniqueKeysWithValues: complete.nodes.indices.map {
            (complete.path(for: $0), complete.nodes[$0])
        })

        #expect(Set(queryReadyByPath.keys) == Set(completeByPath.keys))
        #expect(queryReadyResult.unresolvedPaths.isEmpty)
        for path in completeByPath.keys {
            let first = try #require(queryReadyByPath[path])
            let final = try #require(completeByPath[path])
            #expect(first.isDirectory == final.isDirectory)
            #expect(first.isHiddenScope == final.isHiddenScope)
            #expect(first.isPackageDescendant == final.isPackageDescendant)
            #expect(first.size == 0)
            #expect(first.modifiedTime == 0)
            #expect(first.creationTime == 0)
        }
    }

    @Test func enrichmentWaitIsLimitedToMetadataAndContentQueries() throws {
        var options = SearchOptions()
        options.target = .name

        for queryText in ["needle", "ext:txt", "path:Archive", "folder:Archive"] {
            options.query = queryText
            let query = try SearchQueryPlan.parse(queryText).compile(options: options)
            #expect(!query.requiresCompleteMetadata(options: options))
        }

        options.query = "size:>100b"
        var query = try SearchQueryPlan.parse(options.query).compile(options: options)
        #expect(query.requiresCompleteMetadata(options: options))

        options.query = "content:needle"
        query = try SearchQueryPlan.parse(options.query).compile(options: options)
        #expect(query.requiresCompleteMetadata(options: options))

        options.query = "needle"
        options.target = .content
        query = try SearchQueryPlan.parse(options.query).compile(options: options)
        #expect(query.requiresCompleteMetadata(options: options))
    }

    @Test func coldBuildPublishesCompleteNameTopologyBeforeMetadataFinishes() async throws {
        let root = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cacheURL = createCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let resultPath = root.appendingPathComponent("phase-result.txt").path
        let fullDiskAccess = SearchPermissions.hasFullDiskAccess()
        let signature = SearchIndexSignature(scopes: [root], hasFullDiskAccess: fullDiskAccess)
        let queryReadyNodes = SearchIndexBuilder.assembleIndexedNodes(from: [
            tempNode(path: root.path, isDirectory: true),
            tempNode(path: resultPath),
        ])
        let completeNodes = queryReadyNodes.map { node in
            IndexedFileNode(
                name: node.name,
                parentIndex: node.parentIndex,
                isDirectory: node.isDirectory,
                size: node.isDirectory ? 0 : 4_096,
                modifiedTime: node.isDirectory ? 0 : 200,
                creationTime: node.isDirectory ? 0 : 100,
                isHiddenScope: node.isHiddenScope,
                isPackageDescendant: node.isPackageDescendant
            )
        }
        let (metadataGate, metadataGateContinuation) = AsyncStream.makeStream(of: Void.self)
        defer { metadataGateContinuation.finish() }
        let store = SearchIndexStore(
            persistenceURL: cacheURL,
            queryReadyBuildOperation: { _ in
                SearchIndexBuildResult(nodes: queryReadyNodes, unresolvedPaths: [])
            },
            buildOperation: { _ in
                for await _ in metadataGate { break }
                return SearchIndexBuildResult(nodes: completeNodes, unresolvedPaths: [])
            }
        )

        let refreshTask = Task {
            await store.refresh(scopes: [root], hasFullDiskAccess: fullDiskAccess)
        }
        var publishedQueryReadyStage = false
        for _ in 0..<200 {
            let stats = await store.stats()
            if stats.isIndexing, stats.indexRevision > 0 {
                #expect(stats.isMetadataEnriching)
                publishedQueryReadyStage = true
                break
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(publishedQueryReadyStage)
        let queryReady = await store.snapshot(
            for: [root],
            hasFullDiskAccess: fullDiskAccess,
            requiringCompleteMetadata: false
        )
        #expect(queryReady.signature == signature)
        #expect(!queryReady.hasCompleteMetadata)
        #expect(!FileManager.default.fileExists(atPath: cacheURL.path))

        var options = SearchOptions()
        options.query = "phase-result"
        let query = try SearchQueryPlan.parse(options.query).compile(options: options)
        let queryReadyPaths = Set(queryReady.nameMatches(query: query, options: options).map { $0.path })
        #expect(queryReadyPaths == Set([resultPath]))
        let immediateNameSnapshot = try #require(await SearchEngine.nameResultSnapshot(
            scopes: [root],
            options: options,
            store: store
        ))
        let immediateNamePage = await SearchEngine.materializeNamePage(
            from: immediateNameSnapshot,
            startingAt: 0,
            count: 10
        )
        #expect(immediateNamePage.results.map(\.url.path) == [resultPath])

        var metadataOptions = options
        metadataOptions.query = "size:>100b"
        let metadataSearchTask = Task {
            await SearchEngine.nameResultSnapshot(
                scopes: [root],
                options: metadataOptions,
                store: store
            )
        }
        try await Task.sleep(for: .milliseconds(20))
        metadataGateContinuation.yield(())
        metadataGateContinuation.finish()

        let metadataSnapshot = try #require(await metadataSearchTask.value)
        _ = await refreshTask.value
        #expect(!(await store.stats()).isMetadataEnriching)
        let complete = await store.snapshot(
            for: [root],
            hasFullDiskAccess: fullDiskAccess,
            requiringCompleteMetadata: true
        )
        let completePaths = Set(complete.nameMatches(query: query, options: options).map { $0.path })
        #expect(complete.hasCompleteMetadata)
        #expect(completePaths == queryReadyPaths)
        #expect(complete.nameMatches(query: query, options: options).first?.size == 4_096)
        let metadataPage = await SearchEngine.materializeNamePage(
            from: metadataSnapshot,
            startingAt: 0,
            count: 10
        )
        #expect(metadataPage.results.map(\.url.path) == [resultPath])
        await store.flushPersistence()
        let persisted = try #require(SearchIndexPersistence.load(signature: signature, from: cacheURL))
        #expect(persisted.hasCompleteMetadata)
        #expect(persisted.nameMatches(query: query, options: options).first?.size == 4_096)
    }

    @Test func manualRefreshReusesCompleteSnapshotInsteadOfRebuildingQueryReadyStage() async throws {
        let root = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cacheURL = createCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let nodes = SearchIndexBuilder.assembleIndexedNodes(from: [
            tempNode(path: root.path, isDirectory: true),
            tempNode(path: root.appendingPathComponent("refresh-result.txt").path),
        ])
        let queryReadyBuilds = ThreadSafeCounter()
        let completeBuilds = ThreadSafeCounter()
        let store = SearchIndexStore(
            persistenceURL: cacheURL,
            queryReadyBuildOperation: { _ in
                queryReadyBuilds.increment()
                return SearchIndexBuildResult(nodes: nodes, unresolvedPaths: [])
            },
            buildOperation: { _ in
                completeBuilds.increment()
                return SearchIndexBuildResult(nodes: nodes, unresolvedPaths: [])
            }
        )

        _ = await store.refresh(scopes: [root], hasFullDiskAccess: true)
        #expect(queryReadyBuilds.snapshot() == 1)
        #expect(completeBuilds.snapshot() == 1)

        _ = await store.refresh(scopes: [root], hasFullDiskAccess: true)
        #expect(queryReadyBuilds.snapshot() == 1)
        #expect(completeBuilds.snapshot() == 2)
    }

    @Test func manualRefreshPreservesContentAcceleration() async throws {
        let root = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cacheURL = createCacheURL()
        defer {
            for suffix in ["", ".delta.plist", ".content-v2.sqlite3", ".content-v2.sqlite3-wal", ".content-v2.sqlite3-shm"] {
                try? FileManager.default.removeItem(atPath: cacheURL.deletingPathExtension().path + suffix)
            }
        }
        let fileURL = root.appendingPathComponent("preserved-content.txt")
        try writeFile(at: fileURL, content: "preservedneedle body")
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let modified = attributes[.modificationDate] as? Date ?? .distantPast
        let created = attributes[.creationDate] as? Date ?? modified
        let nodes = SearchIndexBuilder.assembleIndexedNodes(from: [
            tempNode(path: root.path, isDirectory: true),
            TempNode(
                path: fileURL.path,
                name: fileURL.lastPathComponent,
                isDirectory: false,
                size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                modifiedTime: modified.timeIntervalSinceReferenceDate,
                creationTime: created.timeIntervalSinceReferenceDate,
                isHiddenScope: false,
                isPackageDescendant: false
            ),
        ])
        let store = SearchIndexStore(
            persistenceURL: cacheURL,
            buildOperation: { _ in SearchIndexBuildResult(nodes: nodes, unresolvedPaths: []) }
        )
        _ = await store.refresh(scopes: [root], hasFullDiskAccess: true)
        let contentIndex = await store.contentIndexHandle()
        let resolved = ResolvedNode(node: nodes[1], path: fileURL.path)
        await contentIndex.record([
            ContentIndexRecord(node: resolved, text: "preservedneedle body"),
        ])
        #expect((await contentIndex.diagnostics()).indexedDocuments == 1)

        _ = await store.refresh(scopes: [root], hasFullDiskAccess: true)
        #expect((await contentIndex.diagnostics()).indexedDocuments == 1)
    }

    @Test func metadataEnrichmentFailurePreservesQueryReadyCandidates() async throws {
        let root = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cacheURL = createCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let retainedPath = root.appendingPathComponent("retained-name.txt").path
        let queryReadyNodes = SearchIndexBuilder.assembleIndexedNodes(from: [
            tempNode(path: root.path, isDirectory: true),
            tempNode(path: retainedPath),
        ])
        let completeNodes = SearchIndexBuilder.assembleIndexedNodes(from: [
            tempNode(path: root.path, isDirectory: true),
        ])
        let store = SearchIndexStore(
            persistenceURL: cacheURL,
            queryReadyBuildOperation: { _ in
                SearchIndexBuildResult(nodes: queryReadyNodes, unresolvedPaths: [])
            },
            buildOperation: { _ in
                SearchIndexBuildResult(nodes: completeNodes, unresolvedPaths: [retainedPath])
            }
        )

        _ = await store.refresh(scopes: [root], hasFullDiskAccess: true)
        let final = await store.snapshot(
            for: [root],
            hasFullDiskAccess: true,
            requiringCompleteMetadata: true
        )
        var options = SearchOptions()
        options.query = "retained-name"
        let query = try SearchQueryPlan.parse(options.query).compile(options: options)

        #expect(final.hasCompleteMetadata)
        #expect(final.unresolvedPaths == [retainedPath])
        #expect(final.nameMatches(query: query, options: options).map(\.path) == [retainedPath])
    }

    private func collect(scopes: [URL], options: SearchOptions) async -> [SearchResult] {
        let cacheURL = createCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let store = SearchIndexStore(persistenceURL: cacheURL)
        return await collect(scopes: scopes, options: options, store: store)
    }

    private func collect(scopes: [URL], options: SearchOptions, store: SearchIndexStore) async -> [SearchResult] {
        var results: [SearchResult] = []
        for await result in SearchEngine.search(scopes: scopes, options: options, store: store) {
            results.append(result)
        }
        return results
    }

    @Test func testBinarySerializationRoundTrip() async throws {
        let root = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeFile(at: root.appendingPathComponent("file1.txt"))
        try writeFile(at: root.appendingPathComponent("file2.txt"))

        let signature = SearchIndexSignature(scopes: [root])
        let nodes = await SearchIndexBuilder.build(signature: signature)
        let unresolvedPath = root.appendingPathComponent("temporarily-unavailable").path
        let originalIndex = SearchIndex(
            signature: signature,
            nodes: nodes,
            lastEventID: 12345,
            unresolvedPaths: [unresolvedPath]
        )

        let testIndexURL = root.appendingPathComponent("search-index-test.bin")
        SearchIndexPersistence.save(index: originalIndex, to: testIndexURL)

        let loadedIndex = try #require(SearchIndexPersistence.load(signature: signature, from: testIndexURL))
        #expect(loadedIndex.signature == originalIndex.signature)
        #expect(loadedIndex.nodes.count == originalIndex.nodes.count)
        #expect(loadedIndex.lastEventID == 12345)
        #expect(loadedIndex.unresolvedPaths == [unresolvedPath])
        #expect(loadedIndex.stats.unavailablePaths == 1)

        let originalPaths = (0..<originalIndex.nodes.count).map { originalIndex.path(for: $0) }
        let loadedPaths = (0..<loadedIndex.nodes.count).map { loadedIndex.path(for: $0) }
        #expect(Set(originalPaths) == Set(loadedPaths))
        let originalCreationTimes = Dictionary(uniqueKeysWithValues: originalPaths.enumerated().map {
            ($0.element, originalIndex.nodes[$0.offset].creationTime)
        })
        let loadedCreationTimes = Dictionary(uniqueKeysWithValues: loadedPaths.enumerated().map {
            ($0.element, loadedIndex.nodes[$0.offset].creationTime)
        })
        #expect(originalCreationTimes == loadedCreationTimes)

        // The deepIndex flag is part of the signature: a deep-index cache must
        // round-trip as deep, and must not satisfy a non-deep lookup.
        let deepSignature = SearchIndexSignature(scopes: [root], deepIndex: true)
        let deepIndex = SearchIndex(signature: deepSignature, nodes: nodes)
        let deepURL = root.appendingPathComponent("search-index-deep.bin")
        SearchIndexPersistence.save(index: deepIndex, to: deepURL)

        let reloadedDeep = try #require(SearchIndexPersistence.load(signature: deepSignature, from: deepURL))
        #expect(reloadedDeep.signature.deepIndex)
        #expect(SearchIndexPersistence.load(signature: signature, from: deepURL) == nil)
    }

    @Test func largeBaseSnapshotUsesCompressedEnvelopeAndRejectsTruncation() throws {
        let cacheURL = createCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let signature = SearchIndexSignature(scopes: [URL(fileURLWithPath: "/tmp")])
        var nodes = [IndexedFileNode(
            name: "/tmp",
            parentIndex: -1,
            isDirectory: true,
            size: 0,
            modifiedTime: 0,
            creationTime: 0,
            isHiddenScope: false,
            isPackageDescendant: false
        )]
        nodes.reserveCapacity(20_001)
        for index in 0..<20_000 {
            nodes.append(IndexedFileNode(
                name: "repeated-name-\(index % 100).txt",
                parentIndex: 0,
                isDirectory: false,
                size: Int64(index % 10),
                modifiedTime: 0,
                creationTime: 0,
                isHiddenScope: false,
                isPackageDescendant: false
            ))
        }
        let index = SearchIndex(signature: signature, nodes: nodes, pathsAreFresh: true)
        SearchIndexPersistence.save(index: index, to: cacheURL)

        let stored = try Data(contentsOf: cacheURL)
        #expect(String(bytes: stored.prefix(4), encoding: .utf8) == "OFZ1")
        let loaded = try #require(SearchIndexPersistence.load(signature: signature, from: cacheURL))
        #expect(loaded.nodes.count == nodes.count)
        #expect(loaded.nodes.last?.name == nodes.last?.name)

        try stored.prefix(stored.count / 2).write(to: cacheURL, options: .atomic)
        #expect(SearchIndexPersistence.load(signature: signature, from: cacheURL) == nil)
    }

    @Test func refreshPersistsIndexAfterEventReplay() async throws {
        let root = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let cacheURL = createCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        try writeFile(at: root.appendingPathComponent("old_cli_cache_marker.txt"))
        let primingStore = SearchIndexStore(persistenceURL: cacheURL)
        await primingStore.refresh(scopes: [root])
        await primingStore.flushPersistence()

        let freshFile = root.appendingPathComponent("fresh_cli_refresh_target.txt")
        try writeFile(at: freshFile)

        var options = SearchOptions()
        options.target = .name
        options.query = "fresh_cli_refresh_target"

        let staleStore = SearchIndexStore(persistenceURL: cacheURL)
        var replayedResults: [SearchResult] = []
        for _ in 0..<20 {
            replayedResults = await collect(scopes: [root], options: options, store: staleStore)
            if !replayedResults.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        #expect(replayedResults.map(\.name) == ["fresh_cli_refresh_target.txt"])

        await staleStore.refresh(scopes: [root])
        await staleStore.flushPersistence()
        let refreshedResults = await collect(scopes: [root], options: options, store: staleStore)
        #expect(refreshedResults.map(\.name) == ["fresh_cli_refresh_target.txt"])

        let reloadedStore = SearchIndexStore(persistenceURL: cacheURL)
        let reloadedResults = await collect(scopes: [root], options: options, store: reloadedStore)
        #expect(reloadedResults.map(\.name) == ["fresh_cli_refresh_target.txt"])
    }

    @Test func cachedIndexReplaysEventsSinceLastEventID() async throws {
        let root = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let cacheURL = createCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        try writeFile(at: root.appendingPathComponent("old_replay_marker.txt"))
        let signature = SearchIndexSignature(scopes: [root])
        let baselineEventID = FileSystemEventWatcher.currentEventID()
        let nodes = await SearchIndexBuilder.build(signature: signature)
        SearchIndexPersistence.save(
            index: SearchIndex(signature: signature, nodes: nodes, lastEventID: baselineEventID),
            to: cacheURL
        )

        try writeFile(at: root.appendingPathComponent("fresh_replay_target.txt"))

        let store = SearchIndexStore(persistenceURL: cacheURL)
        await store.prepare(scopes: [root], hasFullDiskAccess: true)

        var options = SearchOptions()
        options.target = .name
        options.query = "fresh_replay_target"
        let query = try SearchQueryPlan.parse(options.query).compile(options: options)

        var replayedNames: [String] = []
        for _ in 0..<30 {
            let snapshot = await store.snapshot(for: [root], hasFullDiskAccess: true)
            replayedNames = snapshot.nameMatches(query: query, options: options).map(\.name)
            if replayedNames.contains("fresh_replay_target.txt") {
                break
            }
            try? await Task.sleep(for: .milliseconds(250))
        }

        #expect(replayedNames == ["fresh_replay_target.txt"])
    }

    @Test func persistedReplacementJournalRestoresChangedSubtreeOnLaunch() async throws {
        let root = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let changedDirectory = root.appendingPathComponent("changed", isDirectory: true)
        try FileManager.default.createDirectory(at: changedDirectory, withIntermediateDirectories: true)
        let oldFile = changedDirectory.appendingPathComponent("old_journal_result.txt")
        try writeFile(at: oldFile)

        let cacheURL = createCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        defer { try? FileManager.default.removeItem(at: SearchIndexPersistence.deltaURL(for: cacheURL)) }

        let signature = SearchIndexSignature(scopes: [root])
        let baselineEventID = FileSystemEventWatcher.currentEventID()
        let nodes = await SearchIndexBuilder.build(signature: signature)
        SearchIndexPersistence.save(
            index: SearchIndex(signature: signature, nodes: nodes, lastEventID: baselineEventID),
            to: cacheURL
        )

        try FileManager.default.removeItem(at: oldFile)
        try writeFile(at: changedDirectory.appendingPathComponent("new_journal_result.txt"))
        SearchIndexPersistence.saveDelta(
            signature: signature,
            rootPaths: [changedDirectory.path],
            baseLastEventID: baselineEventID,
            lastEventID: FileSystemEventWatcher.currentEventID(),
            to: cacheURL
        )

        let store = SearchIndexStore(persistenceURL: cacheURL)
        await store.prepare(scopes: [root], hasFullDiskAccess: true)

        var options = SearchOptions()
        options.target = .name
        options.query = "journal_result"
        let query = try SearchQueryPlan.parse(options.query).compile(options: options)
        let snapshot = await store.snapshot(for: [root], hasFullDiskAccess: true)
        let results = snapshot.nameMatches(query: query, options: options)

        #expect(results.map(\.name) == ["new_journal_result.txt"])

        await store.flushPersistence()
        let checkpointedBase = try #require(SearchIndexPersistence.load(
            signature: signature,
            from: cacheURL
        ))
        let checkpointedPaths = Set(checkpointedBase.nodes.indices.map(checkpointedBase.path(for:)))
        #expect(checkpointedPaths.contains(changedDirectory.appendingPathComponent("new_journal_result.txt").path))
        #expect(!checkpointedPaths.contains(oldFile.path))

        let checkpointedDelta = try #require(SearchIndexPersistence.loadDelta(
            signature: signature,
            baseLastEventID: checkpointedBase.lastEventID,
            from: cacheURL
        ))
        #expect(checkpointedDelta.subtreePaths.isEmpty)
    }

    @Test func compactedBaseWriteCanPreserveThePreviousDeltaUntilCheckpoint() async throws {
        let root = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cacheURL = root.appendingPathComponent("preserved-delta.bin")
        let signature = SearchIndexSignature(scopes: [root])
        let base = SearchIndex(
            signature: signature,
            nodes: SearchIndexBuilder.assembleIndexedNodes(from: [
                tempNode(path: root.path, isDirectory: true),
            ]),
            lastEventID: 100
        )
        let changedPath = root.appendingPathComponent("changed").path
        SearchIndexPersistence.saveDelta(
            signature: signature,
            rootPaths: [changedPath],
            baseLastEventID: 100,
            lastEventID: 120,
            to: cacheURL
        )

        SearchIndexPersistence.save(index: base, to: cacheURL, removeDelta: false)

        let preserved = try #require(SearchIndexPersistence.loadDelta(
            signature: signature,
            baseLastEventID: 100,
            from: cacheURL
        ))
        #expect(preserved.subtreePaths == [changedPath])
        #expect(preserved.lastEventID == 120)
    }

    @Test func persistedReplacementJournalRestoresExactFileChangesOnLaunch() async throws {
        let root = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let oldFile = root.appendingPathComponent("old_exact_journal_result.txt")
        try writeFile(at: oldFile)

        let cacheURL = createCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        defer { try? FileManager.default.removeItem(at: SearchIndexPersistence.deltaURL(for: cacheURL)) }

        let signature = SearchIndexSignature(scopes: [root])
        let baselineEventID = FileSystemEventWatcher.currentEventID()
        let nodes = await SearchIndexBuilder.build(signature: signature)
        SearchIndexPersistence.save(
            index: SearchIndex(signature: signature, nodes: nodes, lastEventID: baselineEventID),
            to: cacheURL
        )

        try FileManager.default.removeItem(at: oldFile)
        let newFile = root.appendingPathComponent("new_exact_journal_result.txt")
        try writeFile(at: newFile)
        SearchIndexPersistence.saveDelta(
            signature: signature,
            subtreePaths: [],
            exactPaths: [oldFile.path, newFile.path],
            baseLastEventID: baselineEventID,
            lastEventID: FileSystemEventWatcher.currentEventID(),
            to: cacheURL
        )

        let store = SearchIndexStore(persistenceURL: cacheURL)
        await store.prepare(scopes: [root], hasFullDiskAccess: true)

        var options = SearchOptions()
        options.target = .name
        options.query = "exact_journal_result"
        let query = try SearchQueryPlan.parse(options.query).compile(options: options)
        let snapshot = await store.snapshot(for: [root], hasFullDiskAccess: true)
        let results = snapshot.nameMatches(query: query, options: options)

        #expect(results.map(\.name) == ["new_exact_journal_result.txt"])
    }

    @Test func deltaJournalIsBoundToItsExactBaseGeneration() throws {
        let cacheURL = createCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        defer { try? FileManager.default.removeItem(at: SearchIndexPersistence.deltaURL(for: cacheURL)) }
        let root = URL(fileURLWithPath: "/tmp/openfind-delta-generation")
        let signature = SearchIndexSignature(scopes: [root], deepIndex: true)

        SearchIndexPersistence.saveDelta(
            signature: signature,
            rootPaths: [root.appendingPathComponent("changed").path],
            baseLastEventID: 100,
            lastEventID: 120,
            to: cacheURL
        )

        #expect(SearchIndexPersistence.loadDelta(
            signature: signature,
            baseLastEventID: 99,
            from: cacheURL
        ) == nil)
        let matching = try #require(SearchIndexPersistence.loadDelta(
            signature: signature,
            baseLastEventID: 100,
            from: cacheURL
        ))
        #expect(matching.lastEventID == 120)
    }

    @Test func canonicalDeltaPreservesNestedRootsInsidePartialScanHoles() throws {
        let cacheURL = createCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        defer { try? FileManager.default.removeItem(at: SearchIndexPersistence.deltaURL(for: cacheURL)) }
        let root = URL(fileURLWithPath: "/tmp/openfind-nested-delta")
        let parent = root.appendingPathComponent("parent").path
        let child = root.appendingPathComponent("parent/unreadable/child").path
        let signature = SearchIndexSignature(scopes: [root], deepIndex: true)

        SearchIndexPersistence.saveCanonicalDelta(
            signature: signature,
            subtreePaths: [child, parent, child, parent],
            exactPaths: [child, child],
            baseLastEventID: 200,
            lastEventID: 220,
            to: cacheURL
        )

        let loaded = try #require(SearchIndexPersistence.loadDelta(
            signature: signature,
            baseLastEventID: 200,
            from: cacheURL
        ))
        #expect(loaded.subtreePaths == [parent, child].sorted())
        #expect(loaded.exactPaths == [child])
    }

    @Test func deltaJournalDropsSyntheticDocumentIDTransitions() throws {
        let cacheURL = createCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        defer { try? FileManager.default.removeItem(at: SearchIndexPersistence.deltaURL(for: cacheURL)) }
        let root = URL(fileURLWithPath: "/")
        let realPath = "/tmp/openfind-real-delta-path"
        let syntheticPath = "/.docid/16777233/changed/2406971/src=306963189,dst=306994397"
        let signature = SearchIndexSignature(scopes: [root], deepIndex: true)

        SearchIndexPersistence.saveCanonicalDelta(
            signature: signature,
            subtreePaths: [realPath, syntheticPath],
            exactPaths: [syntheticPath],
            baseLastEventID: 300,
            lastEventID: 320,
            to: cacheURL
        )

        let loaded = try #require(SearchIndexPersistence.loadDelta(
            signature: signature,
            baseLastEventID: 300,
            from: cacheURL
        ))
        #expect(loaded.subtreePaths == [realPath])
        #expect(loaded.exactPaths.isEmpty)
    }

    @Test func testIncrementalIndexingReturnsPartialResults() async throws {
        let root = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let sub1 = root.appendingPathComponent("dir1")
        try FileManager.default.createDirectory(at: sub1, withIntermediateDirectories: true)
        try writeFile(at: sub1.appendingPathComponent("apple_in_dir1.txt"))

        let sub2 = root.appendingPathComponent("dir2")
        try FileManager.default.createDirectory(at: sub2, withIntermediateDirectories: true)
        try writeFile(at: sub2.appendingPathComponent("apple_in_dir2.txt"))

        let cacheURL = createCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let store = SearchIndexStore(persistenceURL: cacheURL)
        let prepareTask = Task {
            await store.prepare(scopes: [root])
        }

        try? await Task.sleep(for: .milliseconds(50))

        let partialIndex = await store.snapshot(for: [root])
        #expect(partialIndex.signature.scopes == [root.path])

        _ = await prepareTask.value

        let finalIndex = await store.snapshot(for: [root])
        #expect(finalIndex.nodes.count > 0)
    }

    @Test func changingScopesNeverReturnsThePreviousSignatureDuringRebuild() async throws {
        let rootA = try createTempDirectory()
        let rootB = try createTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: rootA)
            try? FileManager.default.removeItem(at: rootB)
        }
        try writeFile(at: rootA.appendingPathComponent("only-in-a.txt"))
        try writeFile(at: rootB.appendingPathComponent("only-in-b.txt"))

        let cacheURL = createCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let signatureA = SearchIndexSignature(scopes: [rootA])
        let signatureB = SearchIndexSignature(scopes: [rootB])
        let nodesA = await SearchIndexBuilder.build(signature: signatureA)
        SearchIndexPersistence.save(
            index: SearchIndex(
                signature: signatureA,
                nodes: nodesA,
                lastEventID: FileSystemEventWatcher.currentEventID()
            ),
            to: cacheURL
        )

        let store = SearchIndexStore(
            persistenceURL: cacheURL,
            buildOperation: { signature in
                try? await Task.sleep(for: .milliseconds(150))
                return await SearchIndexBuilder.buildWithDiagnostics(signature: signature)
            }
        )
        await store.prepare(scopes: [rootA], hasFullDiskAccess: true)

        let rebuild = Task {
            await store.prepare(scopes: [rootB], hasFullDiskAccess: true)
        }
        var observedPendingBuild = false
        for _ in 0..<100 {
            if await store.stats().isIndexing {
                observedPendingBuild = true
                break
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
        #expect(observedPendingBuild)

        let snapshot = await store.snapshot(for: [rootB], hasFullDiskAccess: true)
        let paths = Set(snapshot.nodes.indices.map(snapshot.path(for:)))
        #expect(snapshot.signature == signatureB)
        #expect(paths.contains(rootB.appendingPathComponent("only-in-b.txt").path))
        #expect(!paths.contains(rootA.appendingPathComponent("only-in-a.txt").path))
        _ = await rebuild.value
    }

    @Test func eventLogStoresRecentFileSystemEventsWithReadableTypes() async throws {
        let store = SearchIndexStore(persistenceURL: createCacheURL())
        let path = "/tmp/OpenFindEventLogTests/example.txt"
        await store.noteFileEvents([
            FileSystemEvent(
                path: path,
                eventID: 42,
                flags: UInt32(kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemModified),
                receivedAt: Date(timeIntervalSince1970: 100),
                requiresFullRescan: false
            ),
        ])

        let events = await store.recentEventLog()
        #expect(events.count == 1)
        #expect(events[0].name == "example.txt")
        #expect(events[0].locationPath == "/tmp/OpenFindEventLogTests")
        #expect(events[0].localizedEventKeys.contains("Renamed"))
        #expect(events[0].localizedEventKeys.contains("Modified"))
        #expect(events[0].matchesQuery.contains("example.txt"))
    }

    @Test func eventLogKeepsOpenFindCacheEvents() async throws {
        let store = SearchIndexStore(persistenceURL: createCacheURL())
        let path = "\(NSHomeDirectory())/Library/Application Support/OpenFind/search-index-v18.bin"
        await store.noteFileEvents([
            FileSystemEvent(
                path: path,
                eventID: 43,
                flags: UInt32(kFSEventStreamEventFlagItemModified),
                receivedAt: Date(timeIntervalSince1970: 101),
                requiresFullRescan: false
            ),
        ])

        let events = await store.recentEventLog()
        #expect(events.count == 1)
        #expect(events[0].normalizedPath == SearchPath.canonicalAliasPath(path))
        #expect(events[0].name == "search-index-v18.bin")
        #expect(events[0].locationPath.hasSuffix("/Library/Application Support/OpenFind"))
    }

    @Test func indexWatcherFiltersOnlyInternalPersistenceEvents() {
        let baseURL = URL(fileURLWithPath: "/tmp/OpenFind/search-index-v18.bin")
        let deltaURL = SearchIndexPersistence.deltaURL(for: baseURL)
        let ownFlags = UInt32(kFSEventStreamEventFlagOwnEvent | kFSEventStreamEventFlagItemIsFile)

        #expect(SearchIndexPersistence.isInternalIndexEvent(
            path: baseURL.path,
            flags: UInt32(kFSEventStreamEventFlagItemIsFile),
            baseURL: baseURL
        ))
        #expect(SearchIndexPersistence.isInternalIndexEvent(
            path: deltaURL.path,
            flags: UInt32(kFSEventStreamEventFlagItemIsFile),
            baseURL: baseURL
        ))
        #expect(SearchIndexPersistence.isInternalIndexEvent(
            path: "/tmp/OpenFind/.dat.nosync-atomic-temp",
            flags: ownFlags,
            baseURL: baseURL
        ))
        #expect(!SearchIndexPersistence.isInternalIndexEvent(
            path: "/tmp/OpenFind/user-created.txt",
            flags: UInt32(kFSEventStreamEventFlagItemIsFile),
            baseURL: baseURL
        ))
        #expect(!SearchIndexPersistence.isInternalIndexEvent(
            path: "/tmp/user-created.txt",
            flags: ownFlags,
            baseURL: baseURL
        ))
    }
}

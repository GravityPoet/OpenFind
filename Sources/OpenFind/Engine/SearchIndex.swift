import Foundation

struct SearchIndexStats: Sendable, Equatable {
    var indexedFiles = 0
    var indexedDirectories = 0
    var processedEvents = 0
    var isIndexing = false
    var loadedFromDisk = false

    var indexedItems: Int { indexedFiles + indexedDirectories }
}

struct SearchIndexSignature: Codable, Equatable, Sendable {
    let scopes: [String]
    let scopeAliases: [String]
    /// When true the builder drops the noise-filtering ignore list (keeping
    /// only firmlink duplicates), so caches, logs, /Volumes etc. are indexed.
    let deepIndex: Bool

    init(scopes: [URL], deepIndex: Bool = false) {
        let normalized = scopes
            .map { SearchPath.normalize($0.path(percentEncoded: false)) }
            .filter { !$0.isEmpty }
        self.scopes = SearchIndexSignature.collapsedScopes(Array(Set(normalized)))
        self.scopeAliases = SearchIndexSignature.collapsedScopes(Array(Set(
            self.scopes.flatMap(SearchPath.dataVolumeAliases)
        )))
        self.deepIndex = deepIndex
    }

    func contains(path: String) -> Bool {
        let normalized = SearchPath.normalize(path)
        return scopes.contains { SearchPath.hasNormalizedPrefix(normalized, of: $0) }
            || scopeAliases.contains { SearchPath.hasNormalizedPrefix(normalized, of: $0) }
    }

    private static func collapsedScopes(_ scopes: [String]) -> [String] {
        let sorted = scopes.sorted { lhs, rhs in
            let leftDepth = lhs.split(separator: "/").count
            let rightDepth = rhs.split(separator: "/").count
            if leftDepth == rightDepth { return lhs < rhs }
            return leftDepth < rightDepth
        }

        var selected: [String] = []
        for scope in sorted {
            if selected.contains(where: { SearchPath.hasNormalizedPrefix(scope, of: $0) }) {
                continue
            }
            selected.append(scope)
        }
        return selected.sorted()
    }
}

struct IndexedFileNode: Hashable, Sendable {
    let name: String
    let parentIndex: Int32
    let isDirectory: Bool
    let size: Int64
    let modifiedTime: TimeInterval
    let isHiddenScope: Bool
    let isPackageDescendant: Bool
}

struct ResolvedNode: Sendable {
    let node: IndexedFileNode
    let path: String

    var name: String {
        if node.name.hasPrefix("/") {
            return (node.name as NSString).lastPathComponent
        }
        return node.name
    }
    var isDirectory: Bool { node.isDirectory }
    var size: Int64 { node.size }
    var modifiedTime: TimeInterval { node.modifiedTime }

    var url: URL { URL(fileURLWithPath: path) }
    var modifiedDate: Date { Date(timeIntervalSinceReferenceDate: modifiedTime) }

    func searchResult(matchedContent: Bool, preview: String?) -> SearchResult {
        SearchResult(
            url: url,
            name: name,
            path: path,
            isDirectory: isDirectory,
            size: size,
            modified: modifiedDate,
            matchedContent: matchedContent,
            contentPreview: preview
        )
    }
}

struct SearchIndex: Sendable {
    let signature: SearchIndexSignature
    let nodes: [IndexedFileNode]
    let lastEventID: UInt64?
    private let fileCount: Int
    private let directoryCount: Int

    init(signature: SearchIndexSignature, nodes: [IndexedFileNode], lastEventID: UInt64? = nil) {
        self.signature = signature
        self.nodes = nodes
        self.lastEventID = lastEventID

        var files = 0
        var directories = 0
        for node in nodes {
            if node.isDirectory { directories += 1 } else { files += 1 }
        }
        self.fileCount = files
        self.directoryCount = directories
    }

    var stats: SearchIndexStats {
        SearchIndexStats(
            indexedFiles: fileCount,
            indexedDirectories: directoryCount,
            processedEvents: 0,
            isIndexing: false,
            loadedFromDisk: false
        )
    }

    func path(for index: Int) -> String {
        guard index >= 0 && index < nodes.count else { return "" }
        var pathComponents: [String] = []
        var currentIndex = index
        // Depth cap: a corrupted cache with a parentIndex cycle must not hang.
        while currentIndex >= 0 && currentIndex < nodes.count {
            guard pathComponents.count <= 512 else { return "" }
            let node = nodes[currentIndex]
            pathComponents.append(node.name)
            currentIndex = Int(node.parentIndex)
        }

        guard !pathComponents.isEmpty else { return "" }
        var result = pathComponents.last!
        for component in pathComponents.dropLast().reversed() {
            if result == "/" {
                result = "/" + component
            } else {
                result = result + "/" + component
            }
        }
        return result
    }

    func nameMatches(query: CompiledSearchQuery, options: SearchOptions) -> [ResolvedNode] {
        var results: [ResolvedNode] = []
        let pinyin = query.matchesPinyin
        for i in 0..<nodes.count {
            let node = nodes[i]
            let shortName = node.name.hasPrefix("/") ? (node.name as NSString).lastPathComponent : node.name
            guard query.matchesNameFilter(shortName, matchesPinyin: pinyin) else { continue }

            let nodePath = path(for: i)
            if query.matchesNameBranch(name: shortName, node: node, path: nodePath, options: options, matchesPinyin: pinyin) {
                results.append(ResolvedNode(node: node, path: nodePath))
            }
        }
        return SearchRanking.sortedByRelevance(results, query: query, options: options)
    }

    func contentCandidates(query: CompiledSearchQuery, options: SearchOptions, excluding excludedPaths: Set<String> = []) -> [ResolvedNode] {
        var results: [ResolvedNode] = []
        let pinyin = query.matchesPinyin
        for i in 0..<nodes.count {
            let node = nodes[i]
            guard !node.isDirectory else { continue }
            let nodePath = path(for: i)
            guard !excludedPaths.contains(nodePath) else { continue }

            let shortName = node.name.hasPrefix("/") ? (node.name as NSString).lastPathComponent : node.name
            if query.matchesContentCandidate(name: shortName, node: node, path: nodePath, options: options, matchesPinyin: pinyin) {
                results.append(ResolvedNode(node: node, path: nodePath))
            }
        }
        return results.sorted(by: SearchRanking.shallowPathOrder)
    }

    func toTempNodes() -> [TempNode] {
        var tempNodes: [TempNode] = []
        tempNodes.reserveCapacity(nodes.count)
        for i in 0..<nodes.count {
            let node = nodes[i]
            tempNodes.append(TempNode(
                path: path(for: i),
                name: node.name,
                isDirectory: node.isDirectory,
                size: node.size,
                modifiedTime: node.modifiedTime,
                isHiddenScope: node.isHiddenScope,
                isPackageDescendant: node.isPackageDescendant
            ))
        }
        return tempNodes
    }
}

enum SearchRanking {
    static func sortedByRelevance(
        _ matches: [ResolvedNode],
        query: CompiledSearchQuery,
        options: SearchOptions
    ) -> [ResolvedNode] {
        guard let term = query.rankingTerm(options: options) else {
            return matches.sorted(by: shallowPathOrder)
        }
        let needle = term.lowercased()
        return matches
            .map { (node: $0, score: score(name: $0.name, needle: needle), depth: depth(of: $0.path)) }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score < rhs.score }
                if lhs.depth != rhs.depth { return lhs.depth < rhs.depth }
                return lhs.node.path < rhs.node.path
            }
            .map(\.node)
    }

    static func shallowPathOrder(_ lhs: ResolvedNode, _ rhs: ResolvedNode) -> Bool {
        let leftDepth = depth(of: lhs.path)
        let rightDepth = depth(of: rhs.path)
        if leftDepth != rightDepth { return leftDepth < rightDepth }
        return lhs.path < rhs.path
    }

    static func score(name: String, needle: String) -> Int {
        let lower = name.lowercased()
        if lower == needle { return 0 }
        if (lower as NSString).deletingPathExtension == needle { return 0 }
        guard let range = lower.range(of: needle) else { return 3 }
        if range.lowerBound == lower.startIndex { return 1 }
        let before = lower[lower.index(before: range.lowerBound)]
        return (before.isLetter || before.isNumber) ? 3 : 2
    }

    private static func depth(of path: String) -> Int {
        path.utf8.reduce(into: 0) { count, byte in
            if byte == UInt8(ascii: "/") { count += 1 }
        }
    }
}

extension IndexedFileNode {
    func isVisible(with options: SearchOptions) -> Bool {
        if !options.includeHidden && isHiddenScope { return false }
        if !options.includePackages && isPackageDescendant { return false }
        return true
    }
}

actor SearchIndexStore {
    static let shared = SearchIndexStore()

    private let persistenceURL: URL?
    private var index: SearchIndex?
    private var currentSignature: SearchIndexSignature?
    private var currentStats = SearchIndexStats()
    private var watcher: FileSystemEventWatcher?
    private var pendingEventPaths = Set<String>()
    private var pendingEventID: UInt64?
    private var pendingEventsRequireFullRebuild = false
    private var eventRefreshTask: Task<Void, Never>?
    private var backgroundRefreshTask: Task<Void, Never>?
    private var rebuildTask: Task<SearchIndexStats, Never>?
    private var rebuildGeneration = 0
    private var persistTask: Task<Void, Never>?
    private var inProgressSeen = Set<String>()
    private var inProgressPathToIndex: [String: Int32] = [:]
    private var inProgressNodes: [IndexedFileNode] = []
    private var lastPartialPublish: ContinuousClock.Instant?

    init(persistenceURL: URL? = nil) {
        self.persistenceURL = persistenceURL
    }

    func snapshot(for scopes: [URL], deepIndex: Bool = false) async -> SearchIndex {
        let signature = SearchIndexSignature(scopes: scopes, deepIndex: deepIndex)
        if currentSignature == signature {
            return index ?? SearchIndex(signature: signature, nodes: [])
        }

        _ = await prepare(scopes: scopes, deepIndex: deepIndex)
        if let index, index.signature == signature {
            return index
        }

        let nodes = await Task.detached(priority: .userInitiated) {
            await SearchIndexBuilder.build(signature: signature)
        }.value
        return SearchIndex(signature: signature, nodes: nodes)
    }

    @discardableResult
    func prepare(scopes: [URL], deepIndex: Bool = false) async -> SearchIndexStats {
        let signature = SearchIndexSignature(scopes: scopes, deepIndex: deepIndex)
        guard !signature.scopes.isEmpty else {
            cancelPipeline()
            index = SearchIndex(signature: signature, nodes: [])
            currentSignature = signature
            currentStats = SearchIndexStats()
            return currentStats
        }

        if currentSignature == signature {
            if index != nil { return currentStats }
            if let rebuildTask { return await rebuildTask.value }
        }

        cancelPipeline()
        currentSignature = signature
        currentStats = SearchIndexStats()
        return await startRebuild(signature: signature, tryCache: true)
    }

    @discardableResult
    func refresh(scopes: [URL], deepIndex: Bool = false) async -> SearchIndexStats {
        let signature = SearchIndexSignature(scopes: scopes, deepIndex: deepIndex)
        guard !signature.scopes.isEmpty else {
            cancelPipeline()
            index = SearchIndex(signature: signature, nodes: [])
            currentSignature = signature
            currentStats = SearchIndexStats()
            return currentStats
        }

        cancelPipeline()
        currentSignature = signature
        currentStats = SearchIndexStats()
        return await startRebuild(signature: signature, tryCache: false)
    }

    func stats() -> SearchIndexStats {
        currentStats
    }

    func noteFileEvents(_ events: [FileSystemEvent]) {
        guard !events.isEmpty else { return }
        currentStats.processedEvents += events.count
        for event in events {
            if event.eventID > 0 {
                pendingEventID = max(pendingEventID ?? 0, event.eventID)
            }
            if event.requiresFullRescan {
                pendingEventsRequireFullRebuild = true
            }
            if let path = event.path {
                pendingEventPaths.insert(SearchPath.normalize(path))
            }
        }
        scheduleEventRefresh()
    }

    private func cancelPipeline() {
        stopWatching()
        eventRefreshTask?.cancel()
        backgroundRefreshTask?.cancel()
        rebuildTask?.cancel()
        rebuildTask = nil
        rebuildGeneration += 1
        pendingEventPaths.removeAll()
        pendingEventID = nil
        pendingEventsRequireFullRebuild = false
        clearInProgressBuild()
    }

    private func clearInProgressBuild() {
        inProgressSeen = []
        inProgressPathToIndex = [:]
        inProgressNodes = []
        lastPartialPublish = nil
    }

    private func startRebuild(signature: SearchIndexSignature, tryCache: Bool) async -> SearchIndexStats {
        rebuildGeneration += 1
        let generation = rebuildGeneration
        let task = Task {
            await self.loadOrRebuild(signature: signature, tryCache: tryCache, generation: generation)
        }
        rebuildTask = task
        return await task.value
    }

    private func loadOrRebuild(
        signature: SearchIndexSignature,
        tryCache: Bool,
        generation: Int
    ) async -> SearchIndexStats {
        defer {
            if rebuildGeneration == generation { rebuildTask = nil }
        }

        if tryCache {
            let persistenceURL = persistenceURL
            let cached = await Task.detached(priority: .utility) {
                SearchIndexPersistence.load(signature: signature, from: persistenceURL)
            }.value
            guard rebuildGeneration == generation else { return currentStats }
            if let cached {
                index = cached
                var stats = cached.stats
                stats.loadedFromDisk = true
                stats.processedEvents = currentStats.processedEvents
                currentStats = stats
                startWatching(signature: signature, sinceEventID: cached.lastEventID)
                scheduleBackgroundRefresh(signature: signature)
                return currentStats
            }
        }

        currentStats.isIndexing = true
        clearInProgressBuild()
        let baselineEventID = FileSystemEventWatcher.currentEventID()
        let buildTask = Task.detached(priority: .utility) { [signature, generation] in
            await SearchIndexBuilder.build(
                signature: signature,
                progress: { files, directories in
                    Task {
                        await self.updateBuildProgress(
                            signature: signature,
                            generation: generation,
                            files: files,
                            directories: directories
                        )
                    }
                },
                onBatch: { batch in
                    Task {
                        await self.appendBuildBatch(batch, signature: signature, generation: generation)
                    }
                }
            )
        }
        let nodes = await withTaskCancellationHandler {
            await buildTask.value
        } onCancel: {
            buildTask.cancel()
        }

        guard rebuildGeneration == generation else { return currentStats }

        let nextIndex = SearchIndex(signature: signature, nodes: nodes, lastEventID: baselineEventID)
        var stats = nextIndex.stats
        stats.isIndexing = false
        stats.processedEvents = currentStats.processedEvents
        currentStats = stats

        index = nextIndex
        clearInProgressBuild()

        persist(nextIndex)
        startWatching(signature: signature, sinceEventID: nextIndex.lastEventID)
        return currentStats
    }

    /// Incrementally appends one scan batch to the in-progress index so
    /// searches during a build see already-scanned files. Append-only with a
    /// persistent path table (O(batch)); a node arriving before its parent
    /// stores its absolute path, which `path(for:)` returns verbatim, and the
    /// final full build replaces this partial index anyway. Publishing a
    /// snapshot is throttled because `SearchIndex.init` is O(n).
    private func appendBuildBatch(_ batch: [TempNode], signature: SearchIndexSignature, generation: Int) {
        guard rebuildGeneration == generation, currentSignature == signature, currentStats.isIndexing else { return }
        for node in batch {
            guard inProgressSeen.insert(node.path).inserted else { continue }
            let parentPath = (node.path as NSString).deletingLastPathComponent
            let parentIdx = inProgressPathToIndex[parentPath] ?? -1
            let nameToStore = (parentIdx == -1) ? node.path : node.name
            inProgressPathToIndex[node.path] = Int32(inProgressNodes.count)
            inProgressNodes.append(IndexedFileNode(
                name: nameToStore,
                parentIndex: parentIdx,
                isDirectory: node.isDirectory,
                size: node.size,
                modifiedTime: node.modifiedTime,
                isHiddenScope: node.isHiddenScope,
                isPackageDescendant: node.isPackageDescendant
            ))
        }

        let now = ContinuousClock.now
        if let last = lastPartialPublish, now - last < .milliseconds(300) { return }
        lastPartialPublish = now
        index = SearchIndex(signature: signature, nodes: inProgressNodes)
    }

    private func updateBuildProgress(signature: SearchIndexSignature, generation: Int, files: Int, directories: Int) {
        guard rebuildGeneration == generation, currentSignature == signature, currentStats.isIndexing else { return }
        currentStats.indexedFiles = files
        currentStats.indexedDirectories = directories
    }

    private func scheduleBackgroundRefresh(signature: SearchIndexSignature) {
        backgroundRefreshTask = Task {
            try? await Task.sleep(for: .milliseconds(3000))
            guard !Task.isCancelled else { return }
            await self.refreshIfCurrent(signature: signature)
        }
    }

    private func refreshIfCurrent(signature: SearchIndexSignature) async {
        guard currentSignature == signature, rebuildTask == nil else { return }
        _ = await startRebuild(signature: signature, tryCache: false)
    }

    private func scheduleEventRefresh() {
        eventRefreshTask?.cancel()
        let signature = currentSignature
        eventRefreshTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            await self.applyPendingEvents(expectedSignature: signature)
        }
    }

    private func applyPendingEvents(expectedSignature: SearchIndexSignature?) async {
        guard expectedSignature == currentSignature,
              let signature = currentSignature,
              let index else { return }

        let paths = Array(pendingEventPaths)
        let latestEventID = pendingEventID
        let requiresFullRebuild = pendingEventsRequireFullRebuild
        pendingEventPaths.removeAll()
        pendingEventID = nil
        pendingEventsRequireFullRebuild = false

        if requiresFullRebuild {
            currentStats.isIndexing = true
            _ = await startRebuild(signature: signature, tryCache: false)
            return
        }

        guard !paths.isEmpty else {
            if let latestEventID, latestEventID > (index.lastEventID ?? 0) {
                let updatedIndex = SearchIndex(
                    signature: index.signature,
                    nodes: index.nodes,
                    lastEventID: latestEventID
                )
                self.index = updatedIndex
                persist(updatedIndex)
            }
            return
        }

        currentStats.isIndexing = true
        let updatedIndex = await Task.detached(priority: .utility) {
            await SearchIndexBuilder.apply(eventPaths: paths, to: index, signature: signature)
        }.value
        guard expectedSignature == currentSignature else { return }

        let persistedIndex = SearchIndex(
            signature: updatedIndex.signature,
            nodes: updatedIndex.nodes,
            lastEventID: latestEventID ?? index.lastEventID
        )
        self.index = persistedIndex
        var stats = persistedIndex.stats
        stats.processedEvents = currentStats.processedEvents
        currentStats = stats
        persist(persistedIndex)
    }

    private func persist(_ index: SearchIndex) {
        let persistenceURL = persistenceURL
        persistTask = Task.detached(priority: .utility) {
            SearchIndexPersistence.save(index: index, to: persistenceURL)
        }
    }

    func flushPersistence() async {
        await persistTask?.value
    }

    private func startWatching(signature: SearchIndexSignature, sinceEventID: UInt64?) {
        stopWatching()
        watcher = FileSystemEventWatcher(paths: signature.scopes, sinceEventID: sinceEventID) { [weak self] events in
            Task {
                await self?.noteFileEvents(events)
            }
        }
    }

    private func stopWatching() {
        watcher?.stop()
        watcher = nil
    }
}

struct TempNode: Sendable {
    let path: String
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modifiedTime: Double
    let isHiddenScope: Bool
    let isPackageDescendant: Bool
}

/// Work-stealing queue for directory scanning. Workers pull one directory at a
/// time and push its subdirectories back, so a single huge subtree spreads
/// across all workers instead of becoming one task's long tail.
final class ScanCoordinator: @unchecked Sendable {
    enum Slot {
        case path(String)
        case wait
        case done
    }

    private let lock = NSLock()
    private var pending: [String]
    private var inFlight = 0

    init(roots: [String]) {
        pending = roots
    }

    func next() -> Slot {
        lock.lock()
        defer { lock.unlock() }
        if let path = pending.popLast() {
            inFlight += 1
            return .path(path)
        }
        return inFlight == 0 ? .done : .wait
    }

    func complete(subdirectories: [String]) {
        lock.lock()
        pending.append(contentsOf: subdirectories)
        inFlight -= 1
        lock.unlock()
    }
}

final class ProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var files = 0
    private var directories = 0
    private let progress: @Sendable (Int, Int) -> Void

    init(progress: @escaping @Sendable (Int, Int) -> Void) {
        self.progress = progress
    }

    func record(files: Int, directories: Int) {
        lock.lock()
        self.files += files
        self.directories += directories
        let f = self.files
        let d = self.directories
        lock.unlock()

        progress(f, d)
    }
}

enum SearchIndexBuilder {
    private static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey,
        .isSymbolicLinkKey,
        .fileSizeKey,
        .contentModificationDateKey,
        .isHiddenKey,
        .isPackageKey,
        .nameKey,
    ]

    private static let packageExtensions: Set<String> = [
        "app", "bundle", "framework", "plugin", "appex", "xpc", "kext", "pkg",
    ]

    static func build(
        signature: SearchIndexSignature,
        progress: @escaping @Sendable (_ files: Int, _ directories: Int) -> Void = { _, _ in },
        onBatch: @escaping @Sendable ([TempNode]) -> Void = { _ in }
    ) async -> [IndexedFileNode] {
        let ignoredPaths = effectiveIgnoredPaths(for: signature)
        let tracker = ProgressTracker(progress: progress)

        var directNodes: [TempNode] = []
        var rootDirectories: [String] = []
        for scope in signature.scopes {
            guard let scopeNode = makeTempNode(url: URL(fileURLWithPath: scope)) else { continue }
            directNodes.append(scopeNode)
            if scopeNode.isDirectory {
                rootDirectories.append(scope)
            }
        }
        onBatch(directNodes)

        let workerCount = max(4, ProcessInfo.processInfo.activeProcessorCount)
        let coordinator = ScanCoordinator(roots: rootDirectories)

        let scannedNodes = await withTaskGroup(of: [TempNode].self) { group in
            for _ in 0..<workerCount {
                group.addTask {
                    var collected: [TempNode] = []
                    var pendingBatch: [TempNode] = []
                    var localFiles = 0
                    var localDirs = 0
                    var processedDirs = 0

                    while !Task.isCancelled {
                        let slot = coordinator.next()
                        if case .done = slot { break }
                        guard case .path(let directoryPath) = slot else {
                            // Queue momentarily empty while other workers still
                            // expand directories; back off briefly and retry.
                            try? await Task.sleep(for: .milliseconds(2))
                            continue
                        }

                        processedDirs += 1
                        if processedDirs % 16 == 0 {
                            await Task.yield()
                        }

                        var subdirectories: [String] = []
                        let children = (try? FileManager.default.contentsOfDirectory(
                            at: URL(fileURLWithPath: directoryPath),
                            includingPropertiesForKeys: resourceKeys,
                            options: []
                        )) ?? []

                        for child in children {
                            let childPath = SearchPath.normalize(child.path(percentEncoded: false))
                            guard signature.contains(path: childPath) else {
                                continue
                            }
                            if isIgnored(childPath, ignoredPaths: ignoredPaths) { continue }
                            guard let node = makeTempNode(url: child) else { continue }
                            collected.append(node)
                            pendingBatch.append(node)

                            if node.isDirectory {
                                localDirs += 1
                                // Never descend through symlinks: the target is
                                // indexed via its real path, and cycles must not hang.
                                let isSymlink = (try? child.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
                                if !isSymlink {
                                    subdirectories.append(childPath)
                                }
                            } else {
                                localFiles += 1
                            }

                            if (localFiles + localDirs).isMultiple(of: 500) {
                                tracker.record(files: localFiles, directories: localDirs)
                                localFiles = 0
                                localDirs = 0
                            }
                        }

                        coordinator.complete(subdirectories: subdirectories)

                        if pendingBatch.count >= 2048 {
                            onBatch(pendingBatch)
                            pendingBatch.removeAll(keepingCapacity: true)
                        }
                    }

                    if localFiles > 0 || localDirs > 0 {
                        tracker.record(files: localFiles, directories: localDirs)
                    }
                    if !pendingBatch.isEmpty {
                        onBatch(pendingBatch)
                    }
                    return collected
                }
            }

            var combined = directNodes
            for await taskNodes in group {
                combined.append(contentsOf: taskNodes)
            }
            return combined
        }

        let uniqueTempNodes = deduplicatedTempNodes(scannedNodes)

        var filesCount = 0
        var dirsCount = 0
        for node in uniqueTempNodes {
            if node.isDirectory {
                dirsCount += 1
            } else {
                filesCount += 1
            }
        }
        progress(filesCount, dirsCount)

        var pathToIndex: [String: Int32] = [:]
        pathToIndex.reserveCapacity(uniqueTempNodes.count)
        for i in 0..<uniqueTempNodes.count {
            pathToIndex[uniqueTempNodes[i].path] = Int32(i)
        }

        var finalNodes: [IndexedFileNode] = []
        finalNodes.reserveCapacity(uniqueTempNodes.count)
        for node in uniqueTempNodes {
            let parentPath = (node.path as NSString).deletingLastPathComponent
            let parentIdx = pathToIndex[parentPath] ?? -1
            let nameToStore = (parentIdx == -1) ? node.path : node.name
            finalNodes.append(IndexedFileNode(
                name: nameToStore,
                parentIndex: parentIdx,
                isDirectory: node.isDirectory,
                size: node.size,
                modifiedTime: node.modifiedTime,
                isHiddenScope: node.isHiddenScope,
                isPackageDescendant: node.isPackageDescendant
            ))
        }

        return finalNodes
    }

    static func apply(eventPaths: [String], to index: SearchIndex, signature: SearchIndexSignature) async -> SearchIndex {
        let ignoredPaths = effectiveIgnoredPaths(for: signature)
        let scanPaths = collapseEventPaths(eventPaths, signature: signature)
        guard !scanPaths.isEmpty else { return index }

        var tempNodes = index.toTempNodes()
        for path in scanPaths {
            if signature.scopes.contains(path) {
                return SearchIndex(signature: signature, nodes: await build(signature: signature))
            }
            tempNodes.removeAll { SearchPath.hasNormalizedPrefix($0.path, of: path) }
            scanTempPath(path, signature: signature, ignoredPaths: ignoredPaths, into: &tempNodes)
        }

        let uniqueTempNodes = deduplicatedTempNodes(tempNodes)

        var pathToIndex: [String: Int32] = [:]
        pathToIndex.reserveCapacity(uniqueTempNodes.count)
        for i in 0..<uniqueTempNodes.count {
            pathToIndex[uniqueTempNodes[i].path] = Int32(i)
        }

        var finalNodes: [IndexedFileNode] = []
        finalNodes.reserveCapacity(uniqueTempNodes.count)
        for node in uniqueTempNodes {
            let parentPath = (node.path as NSString).deletingLastPathComponent
            let parentIdx = pathToIndex[parentPath] ?? -1
            let nameToStore = (parentIdx == -1) ? node.path : node.name
            finalNodes.append(IndexedFileNode(
                name: nameToStore,
                parentIndex: parentIdx,
                isDirectory: node.isDirectory,
                size: node.size,
                modifiedTime: node.modifiedTime,
                isHiddenScope: node.isHiddenScope,
                isPackageDescendant: node.isPackageDescendant
            ))
        }

        return SearchIndex(signature: signature, nodes: finalNodes)
    }

    static func collapseEventPaths(_ paths: [String], signature: SearchIndexSignature) -> [String] {
        let scoped = paths
            .map(SearchPath.normalize)
            .filter { path in signature.contains(path: path) }
            .sorted { lhs, rhs in
                let leftDepth = lhs.split(separator: "/").count
                let rightDepth = rhs.split(separator: "/").count
                if leftDepth == rightDepth { return lhs < rhs }
                return leftDepth < rightDepth
            }

        var selected: [String] = []
        for path in scoped {
            if selected.contains(where: { SearchPath.hasNormalizedPrefix(path, of: $0) }) {
                continue
            }
            selected.removeAll { SearchPath.hasNormalizedPrefix($0, of: path) }
            selected.append(path)
        }
        return selected
    }

    private static func scanTempPath(
        _ path: String,
        signature: SearchIndexSignature,
        ignoredPaths: [String],
        into nodes: inout [TempNode]
    ) {
        guard signature.contains(path: path),
              !isIgnored(path, ignoredPaths: ignoredPaths) else { return }

        let url = URL(fileURLWithPath: path)
        guard let node = makeTempNode(url: url) else { return }
        nodes.append(node)

        if node.isDirectory {
            let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: resourceKeys,
                options: [],
                errorHandler: { _, _ in true }
            )
            if let enumerator {
                while let item = enumerator.nextObject() as? URL {
                    if Task.isCancelled { return }
                    let itemPath = SearchPath.normalize(item.path(percentEncoded: false))
                    guard signature.contains(path: itemPath) else {
                        continue
                    }

                    if isIgnored(itemPath, ignoredPaths: ignoredPaths) {
                        if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                            enumerator.skipDescendants()
                        }
                        continue
                    }

                    guard let itemNode = makeTempNode(url: item) else { continue }
                    nodes.append(itemNode)
                }
            }
        }
    }

    private static let resourceKeySet = Set(resourceKeys)

    private static func makeTempNode(url: URL) -> TempNode? {
        let values = try? url.resourceValues(forKeys: resourceKeySet)
        let path = SearchPath.normalize(url.path(percentEncoded: false))
        let name = values?.name ?? url.lastPathComponent
        let isDirectory = values?.isDirectory ?? false
        let size = Int64(values?.fileSize ?? 0)
        let modified = values?.contentModificationDate ?? .distantPast
        let components = url.pathComponents
        let isHidden = values?.isHidden == true || components.contains { component in
            component.hasPrefix(".") && component != "." && component != ".."
        }
        let isPackageDescendant = components.dropLast().contains { component in
            packageExtensions.contains((component as NSString).pathExtension.lowercased())
        }

        return TempNode(
            path: path,
            name: name,
            isDirectory: isDirectory,
            size: size,
            modifiedTime: modified.timeIntervalSinceReferenceDate,
            isHiddenScope: isHidden,
            isPackageDescendant: isPackageDescendant
        )
    }

    fileprivate static func deduplicatedTempNodes(_ nodes: [TempNode]) -> [TempNode] {
        var seen = Set<String>()
        seen.reserveCapacity(nodes.count)
        return nodes.filter { seen.insert($0.path).inserted }
    }

    private static func effectiveIgnoredPaths(for signature: SearchIndexSignature) -> [String] {
        let base = signature.deepIndex ? SearchPath.deepIndexIgnoredPaths : SearchPath.defaultIgnoredPaths
        return base.filter { ignored in
            !signature.scopes.contains { scope in
                SearchPath.hasNormalizedPrefix(scope, of: ignored)
            }
        }
    }

    private static func isIgnored(_ path: String, ignoredPaths: [String]) -> Bool {
        ignoredPaths.contains { SearchPath.hasNormalizedPrefix(path, of: $0) }
    }
}

enum SearchIndexPersistence {
    private static let magic = "OFIX"
    private static let version: UInt32 = 5

    private struct BinaryWriter {
        var data = Data()

        mutating func write(bytes: [UInt8]) {
            data.append(contentsOf: bytes)
        }

        mutating func write(_ value: UInt32) {
            let val = value.littleEndian
            data.append(UInt8(val & 0xFF))
            data.append(UInt8((val >> 8) & 0xFF))
            data.append(UInt8((val >> 16) & 0xFF))
            data.append(UInt8((val >> 24) & 0xFF))
        }

        mutating func write(_ value: Int32) {
            write(UInt32(bitPattern: value))
        }

        mutating func write(_ value: Int64) {
            let val = UInt64(bitPattern: value).littleEndian
            write(val)
        }

        mutating func write(_ value: UInt64) {
            let val = value.littleEndian
            data.append(UInt8(val & 0xFF))
            data.append(UInt8((val >> 8) & 0xFF))
            data.append(UInt8((val >> 16) & 0xFF))
            data.append(UInt8((val >> 24) & 0xFF))
            data.append(UInt8((val >> 32) & 0xFF))
            data.append(UInt8((val >> 40) & 0xFF))
            data.append(UInt8((val >> 48) & 0xFF))
            data.append(UInt8((val >> 56) & 0xFF))
        }

        mutating func write(_ value: Double) {
            write(Int64(bitPattern: value.bitPattern))
        }

        mutating func write(_ value: UInt8) {
            data.append(value)
        }

        mutating func write(_ string: String) {
            let utf8 = Array(string.utf8)
            let len = UInt16(min(utf8.count, Int(UInt16.max))).littleEndian
            data.append(UInt8(len & 0xFF))
            data.append(UInt8((len >> 8) & 0xFF))
            data.append(contentsOf: utf8.prefix(Int(len)))
        }
    }

    private struct BinaryReader {
        let data: Data
        var offset = 0

        mutating func readBytes(_ count: Int) -> [UInt8]? {
            guard offset + count <= data.count else { return nil }
            let bytes = Array(data[offset..<offset + count])
            offset += count
            return bytes
        }

        mutating func readUInt32() -> UInt32? {
            guard offset + 4 <= data.count else { return nil }
            let b0 = UInt32(data[offset])
            let b1 = UInt32(data[offset + 1])
            let b2 = UInt32(data[offset + 2])
            let b3 = UInt32(data[offset + 3])
            offset += 4
            return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
        }

        mutating func readInt32() -> Int32? {
            guard let val = readUInt32() else { return nil }
            return Int32(bitPattern: val)
        }

        mutating func readInt64() -> Int64? {
            guard let val = readUInt64() else { return nil }
            return Int64(bitPattern: val)
        }

        mutating func readUInt64() -> UInt64? {
            guard offset + 8 <= data.count else { return nil }
            let b0 = UInt64(data[offset])
            let b1 = UInt64(data[offset + 1])
            let b2 = UInt64(data[offset + 2])
            let b3 = UInt64(data[offset + 3])
            let b4 = UInt64(data[offset + 4])
            let b5 = UInt64(data[offset + 5])
            let b6 = UInt64(data[offset + 6])
            let b7 = UInt64(data[offset + 7])
            offset += 8
            let val = b0 | (b1 << 8) | (b2 << 16) | (b3 << 24) | (b4 << 32) | (b5 << 40) | (b6 << 48) | (b7 << 56)
            return val
        }

        mutating func readDouble() -> Double? {
            guard let val = readInt64() else { return nil }
            return Double(bitPattern: UInt64(bitPattern: val))
        }

        mutating func readUInt8() -> UInt8? {
            guard offset + 1 <= data.count else { return nil }
            let val = data[offset]
            offset += 1
            return val
        }

        mutating func readUInt16() -> UInt16? {
            guard offset + 2 <= data.count else { return nil }
            let b0 = UInt16(data[offset])
            let b1 = UInt16(data[offset + 1])
            offset += 2
            return b0 | (b1 << 8)
        }

        mutating func readString() -> String? {
            guard let len = readUInt16() else { return nil }
            let lenInt = Int(len)
            guard offset + lenInt <= data.count else { return nil }
            let strData = data[offset..<offset + lenInt]
            offset += lenInt
            return String(data: strData, encoding: .utf8)
        }
    }

    static func load(signature: SearchIndexSignature, from url: URL? = nil) -> SearchIndex? {
        let targetURL = url ?? cacheURL
        guard let data = try? Data(contentsOf: targetURL) else { return nil }
        return decode(data, expectedSignature: signature)
    }

    static func save(index: SearchIndex, to url: URL? = nil) {
        let data = encode(index)
        let targetURL = url ?? cacheURL
        do {
            try FileManager.default.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: targetURL, options: .atomic)

            for legacy in ["search-index-v1.plist", "search-index-v2.bin", "search-index-v3.bin", "search-index-v4.bin"] {
                let oldURL = targetURL.deletingLastPathComponent().appendingPathComponent(legacy)
                try? FileManager.default.removeItem(at: oldURL)
            }
        } catch {
            // Cache persistence failure should not break search
        }
    }

    private static var cacheURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("OpenFind", isDirectory: true)
            .appendingPathComponent("search-index-v5.bin")
    }

    private static func encode(_ index: SearchIndex) -> Data {
        var writer = BinaryWriter()
        writer.write(bytes: Array(magic.utf8))
        writer.write(version)
        writer.write(UInt8(index.signature.deepIndex ? 1 : 0))
        writer.write(UInt32(index.signature.scopes.count))
        writer.write(UInt32(index.nodes.count))
        writer.write(index.lastEventID ?? 0)

        var stringPool: [String] = []
        var stringToIndex: [String: UInt32] = [:]

        func getStringIndex(_ s: String) -> UInt32 {
            if let idx = stringToIndex[s] { return idx }
            let idx = UInt32(stringPool.count)
            stringPool.append(s)
            stringToIndex[s] = idx
            return idx
        }

        let scopeIndices = index.signature.scopes.map { getStringIndex($0) }

        struct EncodedNode {
            let parentIndex: Int32
            let nameIndex: UInt32
            let flags: UInt8
            let size: Int64
            let modifiedTime: Double
        }

        var encodedNodes: [EncodedNode] = []
        encodedNodes.reserveCapacity(index.nodes.count)

        for node in index.nodes {
            let nameIdx = getStringIndex(node.name)
            var flags: UInt8 = 0
            if node.isDirectory { flags |= 1 }
            if node.isHiddenScope { flags |= 2 }
            if node.isPackageDescendant { flags |= 4 }

            encodedNodes.append(EncodedNode(
                parentIndex: node.parentIndex,
                nameIndex: nameIdx,
                flags: flags,
                size: node.size,
                modifiedTime: node.modifiedTime
            ))
        }

        for idx in scopeIndices {
            writer.write(idx)
        }

        for node in encodedNodes {
            writer.write(node.parentIndex)
            writer.write(node.nameIndex)
            writer.write(node.flags)
            writer.write(node.size)
            writer.write(node.modifiedTime)
        }

        writer.write(UInt32(stringPool.count))
        for str in stringPool {
            writer.write(str)
        }

        return writer.data
    }

    private static func decode(_ data: Data, expectedSignature: SearchIndexSignature) -> SearchIndex? {
        var reader = BinaryReader(data: data)

        guard let magicBytes = reader.readBytes(4),
              String(bytes: magicBytes, encoding: .utf8) == magic else { return nil }

        guard let ver = reader.readUInt32(), ver == version else { return nil }
        guard let deepIndexByte = reader.readUInt8() else { return nil }
        guard let scopesCount = reader.readUInt32() else { return nil }
        guard let nodesCount = reader.readUInt32() else { return nil }
        guard let encodedLastEventID = reader.readUInt64() else { return nil }

        var scopeIndices: [UInt32] = []
        for _ in 0..<scopesCount {
            guard let idx = reader.readUInt32() else { return nil }
            scopeIndices.append(idx)
        }

        struct TempEncodedNode {
            let parentIndex: Int32
            let nameIndex: UInt32
            let flags: UInt8
            let size: Int64
            let modifiedTime: Double
        }

        var encodedNodes: [TempEncodedNode] = []
        encodedNodes.reserveCapacity(Int(nodesCount))
        for _ in 0..<nodesCount {
            guard let parentIdx = reader.readInt32(),
                  let nameIdx = reader.readUInt32(),
                  let flags = reader.readUInt8(),
                  let size = reader.readInt64(),
                  let modified = reader.readDouble() else { return nil }

            encodedNodes.append(TempEncodedNode(
                parentIndex: parentIdx,
                nameIndex: nameIdx,
                flags: flags,
                size: size,
                modifiedTime: modified
            ))
        }

        guard let poolCount = reader.readUInt32() else { return nil }
        var stringPool: [String] = []
        stringPool.reserveCapacity(Int(poolCount))
        for _ in 0..<poolCount {
            guard let str = reader.readString() else { return nil }
            stringPool.append(str)
        }

        var scopes: [String] = []
        for idx in scopeIndices {
            guard idx < stringPool.count else { return nil }
            scopes.append(stringPool[Int(idx)])
        }

        let loadedSignature = SearchIndexSignature(
            scopes: scopes.map { URL(fileURLWithPath: $0) },
            deepIndex: deepIndexByte == 1
        )
        guard loadedSignature == expectedSignature else { return nil }

        var nodes: [IndexedFileNode] = []
        nodes.reserveCapacity(encodedNodes.count)

        for node in encodedNodes {
            guard node.nameIndex < stringPool.count else { return nil }
            let name = stringPool[Int(node.nameIndex)]
            let isDir = (node.flags & 1) != 0
            let isHidden = (node.flags & 2) != 0
            let isPkg = (node.flags & 4) != 0

            nodes.append(IndexedFileNode(
                name: name,
                parentIndex: node.parentIndex,
                isDirectory: isDir,
                size: node.size,
                modifiedTime: node.modifiedTime,
                isHiddenScope: isHidden,
                isPackageDescendant: isPkg
            ))
        }

        return SearchIndex(
            signature: loadedSignature,
            nodes: nodes,
            lastEventID: encodedLastEventID == 0 ? nil : encodedLastEventID
        )
    }
}

enum SearchPath {
    private static let dataVolumePath = "/System/Volumes/Data"
    private static let dataVolumeAliasRoots: Set<String> = [
        "/Applications",
        "/Library",
        "/Users",
        "/Volumes",
        "/private",
        "/opt",
        "/pkg",
        "/cores",
        "/home",
        "/mnt",
        "/sw",
    ]

    static var defaultIgnoredPaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        return [
            dataVolumePath,
            "/Volumes",
            "\(home)/Library/CloudStorage",
            "\(home)/Library/Biome",
            "\(home)/Library/Caches",
            "\(home)/Library/Logs",
            "\(home)/Library/Metadata",
            "/Library/Caches",
            "/System/Library/Caches",
            "/private/var",
            "/private/tmp",
        ].map(normalize)
    }

    /// Minimal ignore list for deep indexing: only the Data-volume firmlink,
    /// which is the same tree as "/" and would double every node.
    static var deepIndexIgnoredPaths: [String] {
        [dataVolumePath].map(normalize)
    }

    static func dataVolumeAliases(for scope: String) -> [String] {
        let normalized = normalize(scope)
        guard normalized == dataVolumePath || hasNormalizedPrefix(normalized, of: dataVolumePath) else {
            return []
        }

        if normalized == dataVolumePath {
            return dataVolumeAliasRoots.sorted()
        }

        let suffix = normalized.dropFirst(dataVolumePath.count)
        guard suffix.first == "/" else { return [] }
        let alias = String(suffix)
        guard let topLevel = alias.dropFirst().split(separator: "/", maxSplits: 1).first else { return [] }
        let root = "/" + String(topLevel)
        guard dataVolumeAliasRoots.contains(root) else { return [] }
        return [alias]
    }

    static func normalize(_ path: String) -> String {
        // Fast path: enumerator-produced paths are already absolute and clean,
        // and this runs once per scanned node. The URL round-trip below costs
        // microseconds each, which is seconds over a few hundred thousand nodes.
        // "/private" paths must take the slow path: standardizingPath strips the
        // "/private" prefix (e.g. enumerators yield /private/var for /var scopes).
        if path.hasPrefix("/"), path.count > 1, !path.hasSuffix("/"),
           !path.hasPrefix("/private"),
           !path.contains("//"), !path.contains("/./"), !path.contains("/../"),
           !path.hasSuffix("/."), !path.hasSuffix("/..") {
            return path
        }
        let expanded = (path as NSString).expandingTildeInPath
        let standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path(percentEncoded: false)
        guard standardized != "/" else { return "/" }
        return standardized.hasSuffix("/") ? String(standardized.dropLast()) : standardized
    }

    static func isSameOrDescendant(_ path: String, of ancestor: String) -> Bool {
        hasNormalizedPrefix(normalize(path), of: normalize(ancestor))
    }

    static func hasNormalizedPrefix(_ path: String, of ancestor: String) -> Bool {
        if ancestor == "/" { return path.hasPrefix("/") }
        guard path.hasPrefix(ancestor) else { return false }
        let pathBytes = path.utf8
        let ancestorBytes = ancestor.utf8
        if pathBytes.count == ancestorBytes.count { return true }
        return pathBytes.dropFirst(ancestorBytes.count).first == UInt8(ascii: "/")
    }

    /// Scalar-range Han detection. This runs on the per-node hot path during
    /// name matching, where a `\p{Han}` regex would recompile per call.
    static func isHanScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF,      // CJK Extension A
             0x4E00...0x9FFF,      // CJK Unified Ideographs
             0xF900...0xFAFF,      // CJK Compatibility Ideographs
             0x20000...0x2FA1F:    // CJK Extensions B-F
            return true
        default:
            return false
        }
    }

    static func containsHan(_ string: String) -> Bool {
        string.unicodeScalars.contains(where: isHanScalar)
    }

    /// Per-character pinyin initial cache. Distinct Han characters number in
    /// the low thousands, so this stays tiny while eliminating repeated
    /// CFStringTransform calls across names and queries. NSCache is
    /// thread-safe, hence the unsafe opt-out.
    private nonisolated(unsafe) static let pinyinCharCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 65_536
        return cache
    }()

    static func pinyinFirstLetters(from string: String) -> String {
        var result = ""
        for char in string {
            if char.unicodeScalars.contains(where: isHanScalar) {
                let key = String(char) as NSString
                if let cached = pinyinCharCache.object(forKey: key) {
                    result += cached as String
                } else {
                    let mutable = NSMutableString(string: String(char)) as CFMutableString
                    CFStringTransform(mutable, nil, kCFStringTransformToLatin, false)
                    CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)
                    let initial = (mutable as String).first.map(String.init) ?? ""
                    pinyinCharCache.setObject(initial as NSString, forKey: key)
                    result += initial
                }
            } else {
                result.append(char)
            }
        }
        return result.lowercased()
    }
}

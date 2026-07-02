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

    init(scopes: [URL]) {
        let normalized = scopes
            .map { SearchPath.normalize($0.path(percentEncoded: false)) }
            .filter { !$0.isEmpty }
        self.scopes = Array(Set(normalized)).sorted()
    }
}

struct IndexedFileNode: Codable, Hashable, Sendable {
    let path: String
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modifiedTime: TimeInterval
    let isHiddenScope: Bool
    let isPackageDescendant: Bool

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
    private let fileCount: Int
    private let directoryCount: Int

    init(signature: SearchIndexSignature, nodes: [IndexedFileNode]) {
        self.signature = signature
        self.nodes = nodes

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

    func nameMatches(query: CompiledSearchQuery, options: SearchOptions) -> [IndexedFileNode] {
        let matches = nodes.filter { query.matchesNameBranch($0, options: options) }
        return SearchRanking.sortedByRelevance(matches, query: query, options: options)
    }

    func contentCandidates(query: CompiledSearchQuery, options: SearchOptions, excluding excludedPaths: Set<String> = []) -> [IndexedFileNode] {
        nodes.filter { node in
            !excludedPaths.contains(node.path)
            && query.matchesContentCandidate(node, options: options)
        }
        .sorted(by: SearchRanking.shallowPathOrder)
    }
}

/// Orders name matches by how well the name itself matches, Everything-style:
/// exact name (or stem) first, then prefix, then word-boundary hits, then any
/// other substring; ties break toward shallower paths.
enum SearchRanking {
    static func sortedByRelevance(
        _ matches: [IndexedFileNode],
        query: CompiledSearchQuery,
        options: SearchOptions
    ) -> [IndexedFileNode] {
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

    static func shallowPathOrder(_ lhs: IndexedFileNode, _ rhs: IndexedFileNode) -> Bool {
        let leftDepth = depth(of: lhs.path)
        let rightDepth = depth(of: rhs.path)
        if leftDepth != rightDepth { return leftDepth < rightDepth }
        return lhs.path < rhs.path
    }

    /// 0 exact (whole name or name without extension), 1 prefix, 2 substring
    /// starting at a word boundary, 3 any other substring or non-literal match.
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

    private var index: SearchIndex?
    private var currentSignature: SearchIndexSignature?
    private var currentStats = SearchIndexStats()
    private var watcher: FileSystemEventWatcher?
    private var pendingEventPaths = Set<String>()
    private var eventRefreshTask: Task<Void, Never>?
    private var backgroundRefreshTask: Task<Void, Never>?
    /// In-flight load-or-scan for the current signature. Concurrent `prepare`
    /// calls join this task instead of starting duplicate filesystem scans.
    private var rebuildTask: Task<SearchIndexStats, Never>?
    /// Bumped whenever the pipeline is torn down or a new rebuild starts, so a
    /// stale scan that finishes late cannot overwrite newer state.
    private var rebuildGeneration = 0
    private var persistTask: Task<Void, Never>?

    func snapshot(for scopes: [URL]) async -> SearchIndex {
        let signature = SearchIndexSignature(scopes: scopes)
        if currentSignature == signature, let index {
            return index
        }

        _ = await prepare(scopes: scopes)
        if let index, index.signature == signature {
            return index
        }

        // The store was retargeted to another scope set while this request was
        // preparing. Serve it with a one-off scan instead of a wrong or empty
        // index; store state stays owned by the newest scope set.
        let nodes = await Task.detached(priority: .userInitiated) {
            SearchIndexBuilder.build(signature: signature)
        }.value
        return SearchIndex(signature: signature, nodes: nodes)
    }

    @discardableResult
    func prepare(scopes: [URL]) async -> SearchIndexStats {
        let signature = SearchIndexSignature(scopes: scopes)
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

    func stats() -> SearchIndexStats {
        currentStats
    }

    func noteFileEvents(paths: [String]) {
        guard !paths.isEmpty else { return }
        currentStats.processedEvents += paths.count
        for path in paths {
            pendingEventPaths.insert(SearchPath.normalize(path))
        }
        scheduleEventRefresh()
    }

    func resetForTesting() {
        cancelPipeline()
        index = nil
        currentSignature = nil
        currentStats = SearchIndexStats()
    }

    private func cancelPipeline() {
        stopWatching()
        eventRefreshTask?.cancel()
        backgroundRefreshTask?.cancel()
        rebuildTask?.cancel()
        rebuildTask = nil
        rebuildGeneration += 1
        pendingEventPaths.removeAll()
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
            let cached = await Task.detached(priority: .utility) {
                SearchIndexPersistence.load(signature: signature)
            }.value
            guard rebuildGeneration == generation else { return currentStats }
            if let cached {
                index = cached
                var stats = cached.stats
                stats.loadedFromDisk = true
                stats.processedEvents = currentStats.processedEvents
                currentStats = stats
                startWatching(signature: signature)
                scheduleBackgroundRefresh(signature: signature)
                return currentStats
            }
        }

        currentStats.isIndexing = true
        let buildTask = Task.detached(priority: .utility) {
            SearchIndexBuilder.build(signature: signature) { files, directories in
                Task {
                    await SearchIndexStore.shared.updateBuildProgress(
                        signature: signature,
                        files: files,
                        directories: directories
                    )
                }
            }
        }
        let nodes = await withTaskCancellationHandler {
            await buildTask.value
        } onCancel: {
            buildTask.cancel()
        }

        guard rebuildGeneration == generation else { return currentStats }

        let nextIndex = SearchIndex(signature: signature, nodes: nodes)
        index = nextIndex

        var stats = nextIndex.stats
        stats.processedEvents = currentStats.processedEvents
        currentStats = stats

        persist(nextIndex)
        startWatching(signature: signature)
        return currentStats
    }

    private func updateBuildProgress(signature: SearchIndexSignature, files: Int, directories: Int) {
        guard currentSignature == signature, currentStats.isIndexing else { return }
        currentStats.indexedFiles = files
        currentStats.indexedDirectories = directories
    }

    /// After serving a cached index, rescan in the background so staleness is
    /// bounded to one launch (stale-while-revalidate).
    private func scheduleBackgroundRefresh(signature: SearchIndexSignature) {
        backgroundRefreshTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await SearchIndexStore.shared.refreshIfCurrent(signature: signature)
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
            await SearchIndexStore.shared.applyPendingEvents(expectedSignature: signature)
        }
    }

    private func applyPendingEvents(expectedSignature: SearchIndexSignature?) async {
        guard expectedSignature == currentSignature,
              let signature = currentSignature,
              let index else { return }

        let paths = Array(pendingEventPaths)
        pendingEventPaths.removeAll()
        guard !paths.isEmpty else { return }

        currentStats.isIndexing = true
        let updatedIndex = await Task.detached(priority: .utility) {
            SearchIndexBuilder.apply(eventPaths: paths, to: index, signature: signature)
        }.value
        guard expectedSignature == currentSignature else { return }

        self.index = updatedIndex
        var stats = updatedIndex.stats
        stats.processedEvents = currentStats.processedEvents
        currentStats = stats
        persist(updatedIndex)
    }

    private func persist(_ index: SearchIndex) {
        persistTask = Task.detached(priority: .utility) {
            SearchIndexPersistence.save(index: index)
        }
    }

    /// Waits for any in-flight cache write. Needed by short-lived processes
    /// (the CLI) that would otherwise exit before the index hits disk.
    func flushPersistence() async {
        await persistTask?.value
    }

    private func startWatching(signature: SearchIndexSignature) {
        stopWatching()
        watcher = FileSystemEventWatcher(paths: signature.scopes) { paths in
            Task {
                await SearchIndexStore.shared.noteFileEvents(paths: paths)
            }
        }
    }

    private func stopWatching() {
        watcher?.stop()
        watcher = nil
    }
}

enum SearchIndexBuilder {
    private static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey,
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
        progress: @escaping @Sendable (_ files: Int, _ directories: Int) -> Void = { _, _ in }
    ) -> [IndexedFileNode] {
        let ignoredPaths = effectiveIgnoredPaths(for: signature)
        var nodes: [IndexedFileNode] = []
        var files = 0
        var directories = 0

        for scope in signature.scopes {
            scanDescendants(
                of: scope,
                signature: signature,
                ignoredPaths: ignoredPaths,
                into: &nodes,
                files: &files,
                directories: &directories,
                progress: progress
            )
        }

        progress(files, directories)
        return deduplicated(nodes)
    }

    static func apply(eventPaths: [String], to index: SearchIndex, signature: SearchIndexSignature) -> SearchIndex {
        let ignoredPaths = effectiveIgnoredPaths(for: signature)
        let scanPaths = collapseEventPaths(eventPaths, signature: signature)
        guard !scanPaths.isEmpty else { return index }

        var nodes = index.nodes
        for path in scanPaths {
            if signature.scopes.contains(path) {
                return SearchIndex(signature: signature, nodes: build(signature: signature))
            }
            // Both sides are already normalized (index nodes at creation,
            // event paths in collapseEventPaths), so take the fast path.
            nodes.removeAll { SearchPath.hasNormalizedPrefix($0.path, of: path) }
            scanPath(path, signature: signature, ignoredPaths: ignoredPaths, into: &nodes)
        }

        return SearchIndex(signature: signature, nodes: deduplicated(nodes))
    }

    static func collapseEventPaths(_ paths: [String], signature: SearchIndexSignature) -> [String] {
        let scoped = paths
            .map(SearchPath.normalize)
            .filter { path in signature.scopes.contains { SearchPath.hasNormalizedPrefix(path, of: $0) } }
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

    private static func scanPath(
        _ path: String,
        signature: SearchIndexSignature,
        ignoredPaths: [String],
        into nodes: inout [IndexedFileNode]
    ) {
        guard signature.scopes.contains(where: { SearchPath.hasNormalizedPrefix(path, of: $0) }),
              !isIgnored(path, ignoredPaths: ignoredPaths) else { return }

        let url = URL(fileURLWithPath: path)
        guard let node = makeNode(url: url) else { return }
        nodes.append(node)

        if node.isDirectory {
            var files = 0
            var directories = 0
            scanDescendants(
                of: path,
                signature: signature,
                ignoredPaths: ignoredPaths,
                into: &nodes,
                files: &files,
                directories: &directories,
                progress: { _, _ in }
            )
        }
    }

    private static func scanDescendants(
        of scope: String,
        signature: SearchIndexSignature,
        ignoredPaths: [String],
        into nodes: inout [IndexedFileNode],
        files: inout Int,
        directories: inout Int,
        progress: @escaping @Sendable (_ files: Int, _ directories: Int) -> Void
    ) {
        let url = URL(fileURLWithPath: scope)
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: resourceKeys,
            options: [],
            errorHandler: { _, _ in true }
        ) else { return }

        while let item = enumerator.nextObject() as? URL {
            if Task.isCancelled { return }
            let path = SearchPath.normalize(item.path(percentEncoded: false))
            guard signature.scopes.contains(where: { SearchPath.hasNormalizedPrefix(path, of: $0) }) else {
                continue
            }

            if isIgnored(path, ignoredPaths: ignoredPaths) {
                if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard let node = makeNode(url: item) else { continue }
            nodes.append(node)
            recordProgress(node: node, files: &files, directories: &directories, progress: progress)
        }
    }

    private static func recordProgress(
        node: IndexedFileNode,
        files: inout Int,
        directories: inout Int,
        progress: @escaping @Sendable (_ files: Int, _ directories: Int) -> Void
    ) {
        if node.isDirectory {
            directories += 1
        } else {
            files += 1
        }

        if (files + directories).isMultiple(of: 500) {
            progress(files, directories)
        }
    }

    private static func makeNode(url: URL) -> IndexedFileNode? {
        let values = try? url.resourceValues(forKeys: Set(resourceKeys))
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

        return IndexedFileNode(
            path: path,
            name: name,
            isDirectory: isDirectory,
            size: size,
            modifiedTime: modified.timeIntervalSinceReferenceDate,
            isHiddenScope: isHidden,
            isPackageDescendant: isPackageDescendant
        )
    }

    /// Order-preserving dedup. The index itself is unordered; matches are
    /// ranked at query time, so no global sort is needed here.
    private static func deduplicated(_ nodes: [IndexedFileNode]) -> [IndexedFileNode] {
        var seen = Set<String>()
        seen.reserveCapacity(nodes.count)
        return nodes.filter { seen.insert($0.path).inserted }
    }

    private static func effectiveIgnoredPaths(for signature: SearchIndexSignature) -> [String] {
        SearchPath.defaultIgnoredPaths.filter { ignored in
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
    private static let version = 1

    private struct Storage: Codable {
        let version: Int
        let signature: SearchIndexSignature
        let nodes: [IndexedFileNode]
    }

    static func load(signature: SearchIndexSignature) -> SearchIndex? {
        let url = cacheURL
        guard let data = try? Data(contentsOf: url),
              let storage = try? PropertyListDecoder().decode(Storage.self, from: data),
              storage.version == version,
              storage.signature == signature else { return nil }
        return SearchIndex(signature: storage.signature, nodes: storage.nodes)
    }

    static func save(index: SearchIndex) {
        let storage = Storage(version: version, signature: index.signature, nodes: index.nodes)
        guard let data = try? PropertyListEncoder.binary.encode(storage) else { return }
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            // Cache persistence is an optimization; failed writes should not break search.
        }
    }

    private static var cacheURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("OpenFind", isDirectory: true)
            .appendingPathComponent("search-index-v1.plist")
    }
}

enum SearchPath {
    static var defaultIgnoredPaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        return [
            "/System/Volumes/Data",
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

    static func normalize(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path(percentEncoded: false)
        guard standardized != "/" else { return "/" }
        return standardized.hasSuffix("/") ? String(standardized.dropLast()) : standardized
    }

    static func isSameOrDescendant(_ path: String, of ancestor: String) -> Bool {
        hasNormalizedPrefix(normalize(path), of: normalize(ancestor))
    }

    /// Same containment check as `isSameOrDescendant`, but assumes both inputs
    /// are already `normalize`d (index node paths, signature scopes, the
    /// default ignore list). Skips re-normalization, which allocates URLs and
    /// dominates hot scan loops.
    static func hasNormalizedPrefix(_ path: String, of ancestor: String) -> Bool {
        if ancestor == "/" { return path.hasPrefix("/") }
        guard path.hasPrefix(ancestor) else { return false }
        let pathBytes = path.utf8
        let ancestorBytes = ancestor.utf8
        if pathBytes.count == ancestorBytes.count { return true }
        return pathBytes.dropFirst(ancestorBytes.count).first == UInt8(ascii: "/")
    }
}

private extension PropertyListEncoder {
    static var binary: PropertyListEncoder {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return encoder
    }
}

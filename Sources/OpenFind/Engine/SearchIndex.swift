import CoreServices
import Compression
import CryptoKit
import Darwin
import Foundation

struct SearchIndexStats: Sendable, Equatable {
    var indexedFiles = 0
    var indexedDirectories = 0
    var processedEvents = 0
    var unavailablePaths = 0
    var indexRevision = 0
    var isIndexing = false
    /// Stage 1 already contains the complete searchable name/path topology;
    /// Stage 2 is filling size and timestamp metadata in the background.
    var isMetadataEnriching = false
    var loadedFromDisk = false

    var indexedItems: Int { indexedFiles + indexedDirectories }
}

struct SearchIndexSignature: Codable, Equatable, Sendable {
    let scopes: [String]
    let scopeAliases: [String]
    /// Custom scopes whose security-scoped bookmark was created or resolved
    /// successfully. A path supplied by CLI/configuration alone is not an
    /// authorization token and must not bypass macOS privacy prompt guards.
    let authorizedScopePaths: [String]
    /// When true the builder drops the noise-filtering ignore list (keeping
    /// only root-alias duplicates), so caches, logs, and temp folders are indexed.
    let deepIndex: Bool
    /// Records whether macOS has granted broad access. Comprehensive indexing
    /// still attempts every location and lets the OS enforce per-folder access;
    /// lightweight indexing avoids privacy-gated locations without this grant.
    let hasFullDiskAccess: Bool

    init(
        scopes: [URL],
        deepIndex: Bool = false,
        hasFullDiskAccess: Bool = true,
        authorizedScopePaths: [String]? = nil
    ) {
        let normalized = scopes
            .map { SearchPath.canonicalAliasPath($0.path(percentEncoded: false)) }
            .filter { !$0.isEmpty }
        let collapsedScopes = SearchIndexSignature.collapsedScopes(Array(Set(normalized)))
        self.scopes = collapsedScopes
        self.scopeAliases = SearchIndexSignature.collapsedScopes(Array(Set(
            collapsedScopes.flatMap(SearchPath.dataVolumeAliases)
        )))
        let normalizedAuthorizations = (authorizedScopePaths
            ?? ScopeStore.authorizedScopePaths(for: scopes))
            .map(SearchPath.canonicalAliasPath)
            .filter { authorized in
                authorized != SearchScopes.wholeMacPath
                    && collapsedScopes.contains {
                        SearchPath.hasNormalizedPrefix(authorized, of: $0)
                    }
            }
        self.authorizedScopePaths = SearchIndexSignature.collapsedScopes(
            Array(Set(normalizedAuthorizations))
        )
        self.deepIndex = deepIndex
        self.hasFullDiskAccess = hasFullDiskAccess
    }

    func contains(path: String) -> Bool {
        let normalized = SearchPath.canonicalAliasPath(path)
        return containsCanonicalPath(normalized)
    }

    func containsCanonicalPath(_ path: String) -> Bool {
        return scopes.contains { SearchPath.hasNormalizedPrefix(path, of: $0) }
            || scopeAliases.contains { SearchPath.hasNormalizedPrefix(path, of: $0) }
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
    let creationTime: TimeInterval
    let isHiddenScope: Bool
    let isPackageDescendant: Bool
}

/// Lazily reconstructs absolute paths for immutable base-index nodes.
///
/// A broad name-only query can match millions of nodes, while the UI initially
/// needs paths for only one visible page. Keeping the compact parent links in
/// the result tail avoids allocating one full path String per hit. A small,
/// shared cache keeps visible rows and ordinary narrow queries cheap without
/// retaining a second whole-index path table in memory.
final class SearchIndexPathProvider: @unchecked Sendable {
    let identity = UUID()

    private let nodes: [IndexedFileNode]
    private let lock = NSLock()
    private var cachedPaths: [Int32: String] = [:]
    private let maximumCachedPaths = 50_000

    init(nodes: [IndexedFileNode]) {
        self.nodes = nodes
        cachedPaths.reserveCapacity(min(nodes.count, maximumCachedPaths))
    }

    func node(for index: Int32) -> IndexedFileNode {
        let nodeIndex = Int(index)
        guard nodeIndex >= 0, nodeIndex < nodes.count else {
            return IndexedFileNode(
                name: "", parentIndex: -1, isDirectory: false, size: 0,
                modifiedTime: 0, creationTime: 0,
                isHiddenScope: false, isPackageDescendant: false
            )
        }
        return nodes[nodeIndex]
    }

    func path(for index: Int32) -> String {
        let nodeIndex = Int(index)
        guard nodeIndex >= 0, nodeIndex < nodes.count else { return "" }

        lock.lock()
        defer { lock.unlock() }
        if let cached = cachedPaths[index] { return cached }

        var chain: [Int] = []
        chain.reserveCapacity(8)
        var current = nodeIndex
        var basePath: String?

        while current >= 0, current < nodes.count {
            if let cached = cachedPaths[Int32(current)] {
                basePath = cached
                break
            }

            let node = nodes[current]
            let parent = Int(node.parentIndex)
            guard parent >= 0, parent < nodes.count, parent != current else {
                basePath = node.name
                if cachedPaths.count < maximumCachedPaths {
                    cachedPaths[Int32(current)] = node.name
                }
                break
            }
            chain.append(current)
            current = parent
            if chain.count > 512 { return "" }
        }

        guard var path = basePath else { return "" }
        for currentIndex in chain.reversed() {
            let component = nodes[currentIndex].name
            if path == "/" {
                path.append(component)
            } else {
                path.reserveCapacity(path.utf8.count + component.utf8.count + 1)
                path.append("/")
                path.append(component)
            }
            if cachedPaths.count < maximumCachedPaths {
                cachedPaths[Int32(currentIndex)] = path
            }
        }
        return cachedPaths[index] ?? path
    }

    /// Matches `SearchRanking.depth(of:)` without first materializing a path.
    func depth(for index: Int32) -> Int {
        var current = Int(index)
        guard current >= 0, current < nodes.count else { return 0 }

        var edgeCount = 0
        while current >= 0, current < nodes.count {
            let parent = Int(nodes[current].parentIndex)
            guard parent >= 0, parent < nodes.count, parent != current else {
                let root = nodes[current].name
                let rootDepth = root.utf8.reduce(into: 0) { count, byte in
                    if byte == UInt8(ascii: "/") { count += 1 }
                }
                if root == "/", edgeCount > 0 {
                    return max(1, rootDepth + edgeCount - 1)
                }
                return rootDepth + edgeCount
            }
            edgeCount += 1
            current = parent
            if edgeCount > 512 { return 0 }
        }
        return 0
    }
}

enum ResolvedNodeIdentity: Hashable, Sendable {
    case indexed(UUID, Int32)
    case absolute(String)
}

enum ResolvedNodePath: Sendable {
    case indexed(SearchIndexPathProvider, Int32)
    case absolute(String)

    var value: String {
        switch self {
        case .indexed(let provider, let index):
            return provider.path(for: index)
        case .absolute(let path):
            return path
        }
    }

    var depth: Int {
        switch self {
        case .indexed(let provider, let index):
            return provider.depth(for: index)
        case .absolute(let path):
            return path.utf8.reduce(into: 0) { count, byte in
                if byte == UInt8(ascii: "/") { count += 1 }
            }
        }
    }

    var identity: ResolvedNodeIdentity {
        switch self {
        case .indexed(let provider, let index):
            return .indexed(provider.identity, index)
        case .absolute(let path):
            return .absolute(SearchPath.canonicalIndexedPath(path))
        }
    }

    var isDeferred: Bool {
        if case .indexed = self { return true }
        return false
    }
}

/// Event-overlay nodes carry an absolute path and a complete metadata record.
/// Box that uncommon, large payload so the overwhelmingly common indexed case
/// remains a compact provider/index pair in million-result arrays.
private final class AbsoluteResolvedNodeStorage: Sendable {
    let node: IndexedFileNode
    let path: String

    init(node: IndexedFileNode, path: String) {
        self.node = node
        self.path = path
    }
}

private enum ResolvedNodeStorage: Sendable {
    case indexed(SearchIndexPathProvider, Int32)
    case absolute(AbsoluteResolvedNodeStorage)

    var node: IndexedFileNode {
        switch self {
        case .indexed(let provider, let index):
            return provider.node(for: index)
        case .absolute(let storage):
            return storage.node
        }
    }

    var pathReference: ResolvedNodePath {
        switch self {
        case .indexed(let provider, let index):
            return .indexed(provider, index)
        case .absolute(let storage):
            return .absolute(storage.path)
        }
    }
}

struct ResolvedNode: Sendable {
    private let storage: ResolvedNodeStorage

    init(node: IndexedFileNode, path: String) {
        storage = .absolute(AbsoluteResolvedNodeStorage(node: node, path: path))
    }

    init(index: Int, pathProvider: SearchIndexPathProvider) {
        storage = .indexed(pathProvider, Int32(index))
    }

    var node: IndexedFileNode { storage.node }
    var pathReference: ResolvedNodePath { storage.pathReference }

    var name: String {
        if node.name.hasPrefix("/") {
            return (node.name as NSString).lastPathComponent
        }
        return node.name
    }
    var isDirectory: Bool { node.isDirectory }
    var size: Int64 { node.size }
    var modifiedTime: TimeInterval { node.modifiedTime }
    var creationTime: TimeInterval { node.creationTime }
    var path: String { pathReference.value }
    var pathDepth: Int { pathReference.depth }
    var identity: ResolvedNodeIdentity { pathReference.identity }
    var isPathDeferred: Bool { pathReference.isDeferred }
    var indexedOrder: Int32? {
        if case .indexed(_, let index) = pathReference { return index }
        return nil
    }

    /// The index already knows the node kind. Supplying the directory hint is
    /// essential for broad searches: Foundation otherwise calls `lstat` while
    /// constructing every file URL, even when the index snapshot is fresh.
    var url: URL { URL(fileURLWithPath: path, isDirectory: isDirectory) }
    var modifiedDate: Date { Date(timeIntervalSinceReferenceDate: modifiedTime) }
    var createdDate: Date { Date(timeIntervalSinceReferenceDate: creationTime) }

    func searchResult(matchedContent: Bool, preview: String?) -> SearchResult {
        SearchResult(
            resolvedNode: self,
            matchedContent: matchedContent,
            contentPreview: preview
        )
    }
}

/// Four-byte references for complete name-search snapshots. Nonnegative
/// values address immutable base nodes; negative values address the small
/// event-overlay array using `-1 - index`.
struct SearchIndexCompactNameMatches: Sendable {
    fileprivate let references: [Int32]
    fileprivate let overlayNodes: [ResolvedNode]
    fileprivate let pathProvider: SearchIndexPathProvider

    var count: Int { references.count }

    func node(at position: Int) -> ResolvedNode {
        let reference = references[position]
        if reference >= 0 {
            return ResolvedNode(index: Int(reference), pathProvider: pathProvider)
        }
        return overlayNodes[Int(-1 - Int64(reference))]
    }

    fileprivate static func overlayReference(for index: Int) -> Int32? {
        guard index >= 0, index < Int(Int32.max) else { return nil }
        return -1 - Int32(index)
    }
}

struct SearchIndexReplacement: Sendable {
    let rootPath: String
    let nodes: [TempNode]
    /// Enumeration can fail for one descendant while the rest of a subtree is
    /// readable. Keep the previous base snapshot visible for those prefixes
    /// instead of silently masking files that were not rescanned.
    let preservedBaseRoots: [String]
    fileprivate let nameIndex: SearchNameIndex?

    init(rootPath: String, nodes: [TempNode], preservedBaseRoots: [String] = []) {
        self.rootPath = rootPath
        self.nodes = nodes
        self.preservedBaseRoots = preservedBaseRoots
        nameIndex = nodes.count >= 1_024 ? SearchNameIndex(tempNodes: nodes) : nil
    }
}

struct SearchIndexExactReplacement: Sendable {
    let path: String
    let node: TempNode?
    /// `false` means metadata could not be read and absence was not proven.
    /// Such a result must preserve the previous snapshot and be retried.
    let isComplete: Bool

    init(path: String, node: TempNode?, isComplete: Bool = true) {
        self.path = path
        self.node = node
        self.isComplete = isComplete
    }
}

struct SearchIndexChanges: Sendable {
    let subtreeReplacements: [SearchIndexReplacement]
    let exactReplacements: [SearchIndexExactReplacement]
    let requiresConservativeRefresh: Bool

    static let empty = SearchIndexChanges(
        subtreeReplacements: [],
        exactReplacements: [],
        requiresConservativeRefresh: false
    )
}

struct SearchIndexObservation: Sendable {
    let stats: SearchIndexStats
    /// `nil` means the revision cannot be fully explained by retained event
    /// batches (for example cache restore or a full rebuild), so callers must
    /// refresh conservatively.
    let changes: SearchIndexChanges?
}

/// Compact reverse lookup from each distinct filename to every base-node index
/// carrying that name. Whole-Mac indexes contain many repeated names; checking
/// each unique name once preserves exact results while avoiding millions of
/// duplicate matcher evaluations on every query.
fileprivate final class MappedSearchNameIndexFile: @unchecked Sendable {
    let data: Data

    init(data: Data) {
        self.data = data
    }

    @inline(__always)
    func int32(at offset: Int) -> Int32 {
        data.withUnsafeBytes {
            Int32(bitPattern: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian)
        }
    }

    @inline(__always)
    func uint64(at offset: Int) -> UInt64 {
        data.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self).littleEndian
        }
    }

    func allInt32(
        at offset: Int,
        count: Int,
        satisfy predicate: (Int32) -> Bool
    ) -> Bool {
        data.withUnsafeBytes { bytes in
            for index in 0..<count {
                let value = Int32(bitPattern: bytes.loadUnaligned(
                    fromByteOffset: offset + index * MemoryLayout<UInt32>.stride,
                    as: UInt32.self
                ).littleEndian)
                if !predicate(value) { return false }
            }
            return true
        }
    }
}

fileprivate enum SearchNameIndexInt32Storage: Sendable {
    case heap([Int32])
    case mapped(MappedSearchNameIndexFile, offset: Int, count: Int)

    var count: Int {
        switch self {
        case .heap(let values): values.count
        case .mapped(_, _, let count): count
        }
    }

    @inline(__always)
    func value(at index: Int) -> Int32 {
        switch self {
        case .heap(let values):
            values[index]
        case .mapped(let file, let offset, _):
            file.int32(at: offset + index * MemoryLayout<UInt32>.stride)
        }
    }

    func appendRawLittleEndian(to data: inout Data) {
        switch self {
        case .heap(let values):
            values.withUnsafeBufferPointer {
                data.append(contentsOf: UnsafeRawBufferPointer($0))
            }
        case .mapped(let file, let offset, let count):
            data.append(file.data[offset..<(offset + count * MemoryLayout<UInt32>.stride)])
        }
    }
}

fileprivate enum SearchNameIndexUInt64Storage: Sendable {
    case heap([UInt64])
    case mapped(MappedSearchNameIndexFile, offset: Int, count: Int)

    var count: Int {
        switch self {
        case .heap(let values): values.count
        case .mapped(_, _, let count): count
        }
    }

    @inline(__always)
    func value(at index: Int) -> UInt64 {
        switch self {
        case .heap(let values):
            values[index]
        case .mapped(let file, let offset, _):
            file.uint64(at: offset + index * MemoryLayout<UInt64>.stride)
        }
    }

    func appendRawLittleEndian(to data: inout Data) {
        switch self {
        case .heap(let values):
            values.withUnsafeBufferPointer {
                data.append(contentsOf: UnsafeRawBufferPointer($0))
            }
        case .mapped(let file, let offset, let count):
            data.append(file.data[offset..<(offset + count * MemoryLayout<UInt64>.stride)])
        }
    }
}

final class SearchNameIndex: Sendable {
    static let namesPerBlock = 16
    private static let maximumStableCandidateNodes = 100_000

    private static let sidecarMagic = "OFNI"
    private static let sidecarVersion: UInt32 = 1
    private static let sidecarHeaderBytes = 56
    private static let sidecarChecksumBytes = 32
    private static let minimumPersistedNodeCount = 1_024
    private static let maximumSidecarBytes: Int64 = 2 * 1_024 * 1_024 * 1_024

    private let heapNames: [String]?
    private let baseNodes: [IndexedFileNode]?
    private let representativeNodeIndices: [Int32]
    private let postingOffsets: [Int32]
    private let postingNodeIndices: SearchNameIndexInt32Storage
    private let blockSignatures: SearchNameIndexUInt64Storage
    /// Character / bigram signatures used for short ASCII queries. Trigram
    /// filtering cannot help with a one- or two-character term, yet those
    /// terms are common broad searches on a whole-Mac index.
    private let shortBlockSignatures: SearchNameIndexUInt64Storage
    /// Name-group-level trigram postings. Block signatures are intentionally
    /// coarse (16 names per block) and saturate on a whole-Mac index. These
    /// transposed bitsets retain the same lossless hash prefilter while
    /// jumping directly to candidate names. A collision only adds a group;
    /// it can never hide a real match.
    private let groupBitsetWordCount: Int
    private let groupPresence: SearchNameIndexUInt64Storage

    var nameCount: Int { representativeNodeIndices.count }
    var isMapped: Bool {
        if case .mapped = postingNodeIndices { return true }
        return false
    }

    convenience init?(
        nodes: [IndexedFileNode],
        yieldsToForegroundSearches: Bool = false
    ) {
        self.init(
            nameCount: nodes.count,
            yieldsToForegroundSearches: yieldsToForegroundSearches
        ) { index in
            let name = nodes[index].name
            return name.hasPrefix("/") ? (name as NSString).lastPathComponent : name
        }
    }

    convenience init?(tempNodes: [TempNode]) {
        self.init(nameCount: tempNodes.count, yieldsToForegroundSearches: false) {
            tempNodes[$0].name
        }
    }

    private init?(
        nameCount: Int,
        yieldsToForegroundSearches: Bool,
        nameAt: (Int) -> String
    ) {
        guard nameCount > 0, nameCount <= Int(Int32.max) else { return nil }

        var uniqueNames: [String] = []
        uniqueNames.reserveCapacity(min(nameCount, 1_000_000))
        var representatives: [Int32] = []
        representatives.reserveCapacity(min(nameCount, 1_000_000))
        var nameToGroup: [String: Int32] = [:]
        nameToGroup.reserveCapacity(min(nameCount, 1_000_000))
        var groupForNode: [Int32] = []
        groupForNode.reserveCapacity(nameCount)

        for index in 0..<nameCount {
            if yieldsToForegroundSearches, index.isMultiple(of: 4_096) {
                SearchWorkCoordinator.shared.waitForSearchesToFinish()
            }
            let shortName = nameAt(index)
            if let group = nameToGroup[shortName] {
                groupForNode.append(group)
            } else {
                let group = Int32(uniqueNames.count)
                uniqueNames.append(shortName)
                representatives.append(Int32(index))
                nameToGroup[shortName] = group
                groupForNode.append(group)
            }
        }

        var counts = [Int32](repeating: 0, count: uniqueNames.count)
        for (index, group) in groupForNode.enumerated() {
            if yieldsToForegroundSearches, index.isMultiple(of: 4_096) {
                SearchWorkCoordinator.shared.waitForSearchesToFinish()
            }
            counts[Int(group)] += 1
        }

        var groupOffsets = [Int32](repeating: 0, count: uniqueNames.count + 1)
        for group in counts.indices {
            if yieldsToForegroundSearches, group.isMultiple(of: 4_096) {
                SearchWorkCoordinator.shared.waitForSearchesToFinish()
            }
            groupOffsets[group + 1] = groupOffsets[group] + counts[group]
        }
        var cursors = Array(groupOffsets.dropLast())
        var groupedNodeIndices = [Int32](repeating: 0, count: nameCount)
        for (nodeIndex, group) in groupForNode.enumerated() {
            if yieldsToForegroundSearches, nodeIndex.isMultiple(of: 4_096) {
                SearchWorkCoordinator.shared.waitForSearchesToFinish()
            }
            let groupIndex = Int(group)
            let destination = Int(cursors[groupIndex])
            groupedNodeIndices[destination] = Int32(nodeIndex)
            cursors[groupIndex] += 1
        }

        heapNames = uniqueNames
        baseNodes = nil
        representativeNodeIndices = representatives
        postingOffsets = groupOffsets
        postingNodeIndices = .heap(groupedNodeIndices)

        let blockCount = (uniqueNames.count + Self.namesPerBlock - 1) / Self.namesPerBlock
        var signatures = [UInt64](repeating: 0, count: blockCount * 4)
        var shortSignatures = [UInt64](repeating: 0, count: blockCount * 4)
        let groupWordCount = (uniqueNames.count + 63) / 64
        var groupBits = [UInt64](repeating: 0, count: 256 * groupWordCount)
        var trigramScratch = [UInt64](repeating: 0, count: 4)
        var shortScratch = [UInt64](repeating: 0, count: 4)
        for (group, name) in uniqueNames.enumerated() {
            if yieldsToForegroundSearches, group.isMultiple(of: 4_096) {
                SearchWorkCoordinator.shared.waitForSearchesToFinish()
            }
            let base = (group / Self.namesPerBlock) * 4
            for lane in 0..<4 {
                trigramScratch[lane] = 0
                shortScratch[lane] = 0
            }
            Self.addTrigrams(from: name, to: &trigramScratch, base: 0)
            Self.addShortNGrams(from: name, to: &shortScratch, base: 0)
            if SearchPath.containsHan(name) {
                let pinyin = SearchPath.pinyinFirstLetters(from: name)
                Self.addTrigrams(
                    from: pinyin,
                    to: &trigramScratch,
                    base: 0
                )
                Self.addShortNGrams(from: pinyin, to: &shortScratch, base: 0)
            }
            let groupWord = group / 64
            let groupMask = UInt64(1) << UInt64(group % 64)
            for lane in 0..<4 {
                signatures[base + lane] |= trigramScratch[lane]
                shortSignatures[base + lane] |= shortScratch[lane]
                var bits = trigramScratch[lane]
                while bits != 0 {
                    let bit = (lane * 64) + bits.trailingZeroBitCount
                    groupBits[bit * groupWordCount + groupWord] |= groupMask
                    bits &= bits &- 1
                }
            }
        }
        blockSignatures = .heap(signatures)
        shortBlockSignatures = .heap(shortSignatures)
        groupBitsetWordCount = groupWordCount
        groupPresence = .heap(groupBits)
    }

    private init(
        baseNodes: [IndexedFileNode],
        representativeNodeIndices: [Int32],
        postingOffsets: [Int32],
        postingNodeIndices: SearchNameIndexInt32Storage,
        blockSignatures: SearchNameIndexUInt64Storage,
        shortBlockSignatures: SearchNameIndexUInt64Storage,
        groupBitsetWordCount: Int,
        groupPresence: SearchNameIndexUInt64Storage
    ) {
        heapNames = nil
        self.baseNodes = baseNodes
        self.representativeNodeIndices = representativeNodeIndices
        self.postingOffsets = postingOffsets
        self.postingNodeIndices = postingNodeIndices
        self.blockSignatures = blockSignatures
        self.shortBlockSignatures = shortBlockSignatures
        self.groupBitsetWordCount = groupBitsetWordCount
        self.groupPresence = groupPresence
    }

    @inline(__always)
    func name(at group: Int) -> String {
        if let heapNames { return heapNames[group] }
        guard let baseNodes else { return "" }
        let rawName = baseNodes[Int(representativeNodeIndices[group])].name
        return rawName.hasPrefix("/") ? (rawName as NSString).lastPathComponent : rawName
    }

    @inline(__always)
    func postingRange(for group: Int) -> Range<Int> {
        Int(postingOffsets[group])..<Int(postingOffsets[group + 1])
    }

    @inline(__always)
    func nodeIndex(at posting: Int) -> Int {
        Int(postingNodeIndices.value(at: posting))
    }

    static func loadMapped(
        nodes: [IndexedFileNode],
        baseDigest: Data,
        from url: URL
    ) -> SearchNameIndex? {
        guard baseDigest.count == SHA256.Digest.byteCount,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              Int64(data.count) <= maximumSidecarBytes,
              data.count >= sidecarHeaderBytes + sidecarChecksumBytes,
              data.starts(with: sidecarMagic.utf8) else { return nil }

        let file = MappedSearchNameIndexFile(data: data)
        guard UInt32(bitPattern: file.int32(at: 4)) == sidecarVersion,
              Data(data[8..<40]) == baseDigest else { return nil }

        let nodeCount = Int(UInt32(bitPattern: file.int32(at: 40)))
        let groupCount = Int(UInt32(bitPattern: file.int32(at: 44)))
        let storedBlockCount = Int(UInt32(bitPattern: file.int32(at: 48)))
        let storedGroupWordCount = Int(UInt32(bitPattern: file.int32(at: 52)))
        guard nodeCount == nodes.count,
              nodeCount >= minimumPersistedNodeCount,
              groupCount > 0,
              groupCount <= nodeCount,
              storedBlockCount == (groupCount + namesPerBlock - 1) / namesPerBlock,
              storedGroupWordCount == (groupCount + 63) / 64,
              expectedSidecarByteCount(nodeCount: nodeCount, groupCount: groupCount) == data.count else {
            return nil
        }

        let checksumOffset = data.count - sidecarChecksumBytes
        let expectedChecksum = Data(data[checksumOffset..<data.count])
        let actualChecksum = Data(SHA256.hash(data: data.prefix(checksumOffset)))
        guard actualChecksum == expectedChecksum else { return nil }

        let representativesOffset = sidecarHeaderBytes
        let offsetsOffset = representativesOffset + groupCount * MemoryLayout<UInt32>.stride
        let nodeIndicesOffset = offsetsOffset + (groupCount + 1) * MemoryLayout<UInt32>.stride
        let blockSignaturesOffset = nodeIndicesOffset + nodeCount * MemoryLayout<UInt32>.stride
        let blockSignatureCount = storedBlockCount * 4
        let shortBlockSignaturesOffset = blockSignaturesOffset
            + blockSignatureCount * MemoryLayout<UInt64>.stride
        let groupPresenceOffset = shortBlockSignaturesOffset
            + blockSignatureCount * MemoryLayout<UInt64>.stride
        let groupPresenceCount = 256 * storedGroupWordCount
        guard groupPresenceOffset + groupPresenceCount * MemoryLayout<UInt64>.stride == checksumOffset,
              file.allInt32(at: nodeIndicesOffset, count: nodeCount, satisfy: {
                  $0 >= 0 && Int($0) < nodeCount
              }) else { return nil }

        var representatives: [Int32] = []
        representatives.reserveCapacity(groupCount)
        for group in 0..<groupCount {
            let value = file.int32(
                at: representativesOffset + group * MemoryLayout<UInt32>.stride
            )
            guard value >= 0, Int(value) < nodeCount else { return nil }
            representatives.append(value)
        }

        var offsets: [Int32] = []
        offsets.reserveCapacity(groupCount + 1)
        var previous: Int32 = 0
        for group in 0...groupCount {
            let value = file.int32(at: offsetsOffset + group * MemoryLayout<UInt32>.stride)
            guard value >= previous, Int(value) <= nodeCount else { return nil }
            if group == 0, value != 0 { return nil }
            previous = value
            offsets.append(value)
        }
        guard offsets.last == Int32(nodeCount) else { return nil }

        return SearchNameIndex(
            baseNodes: nodes,
            representativeNodeIndices: representatives,
            postingOffsets: offsets,
            postingNodeIndices: .mapped(file, offset: nodeIndicesOffset, count: nodeCount),
            blockSignatures: .mapped(
                file,
                offset: blockSignaturesOffset,
                count: blockSignatureCount
            ),
            shortBlockSignatures: .mapped(
                file,
                offset: shortBlockSignaturesOffset,
                count: blockSignatureCount
            ),
            groupBitsetWordCount: storedGroupWordCount,
            groupPresence: .mapped(
                file,
                offset: groupPresenceOffset,
                count: groupPresenceCount
            )
        )
    }

    func sidecarData(baseDigest: Data) -> Data? {
        guard baseDigest.count == SHA256.Digest.byteCount,
              nameCount > 0,
              nameCount <= Int(UInt32.max),
              postingOffsets.count == nameCount + 1,
              postingNodeIndices.count <= Int(UInt32.max),
              representativeNodeIndices.count == nameCount else { return nil }

        let nodeCount = postingNodeIndices.count
        guard nodeCount >= Self.minimumPersistedNodeCount else { return nil }
        let blockCount = (nameCount + Self.namesPerBlock - 1) / Self.namesPerBlock
        let blockSignatureCount = blockCount * 4
        let expectedGroupWordCount = (nameCount + 63) / 64
        let groupPresenceCount = 256 * expectedGroupWordCount
        guard blockSignatures.count == blockSignatureCount,
              shortBlockSignatures.count == blockSignatureCount,
              groupBitsetWordCount == expectedGroupWordCount,
              groupPresence.count == groupPresenceCount,
              let expectedBytes = Self.expectedSidecarByteCount(
                  nodeCount: nodeCount,
                  groupCount: nameCount
              ),
              Int64(expectedBytes) <= Self.maximumSidecarBytes else { return nil }

        var data = Data()
        data.reserveCapacity(expectedBytes)

        func appendUInt32(_ value: UInt32) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        func appendInt32Array(_ values: [Int32]) {
            values.withUnsafeBufferPointer {
                data.append(contentsOf: UnsafeRawBufferPointer($0))
            }
        }

        data.append(contentsOf: Self.sidecarMagic.utf8)
        appendUInt32(Self.sidecarVersion)
        data.append(baseDigest)
        appendUInt32(UInt32(nodeCount))
        appendUInt32(UInt32(nameCount))
        appendUInt32(UInt32(blockCount))
        appendUInt32(UInt32(expectedGroupWordCount))
        appendInt32Array(representativeNodeIndices)
        appendInt32Array(postingOffsets)
        postingNodeIndices.appendRawLittleEndian(to: &data)
        blockSignatures.appendRawLittleEndian(to: &data)
        shortBlockSignatures.appendRawLittleEndian(to: &data)
        groupPresence.appendRawLittleEndian(to: &data)
        data.append(contentsOf: SHA256.hash(data: data))
        return data.count == expectedBytes ? data : nil
    }

    private static func expectedSidecarByteCount(
        nodeCount: Int,
        groupCount: Int
    ) -> Int? {
        guard nodeCount > 0, groupCount > 0, groupCount <= nodeCount else { return nil }
        let blockCount = (groupCount + namesPerBlock - 1) / namesPerBlock
        let groupWordCount = (groupCount + 63) / 64
        let total = Int64(sidecarHeaderBytes)
            + Int64(groupCount) * 4
            + Int64(groupCount + 1) * 4
            + Int64(nodeCount) * 4
            + Int64(blockCount) * 4 * 8 * 2
            + Int64(groupWordCount) * 256 * 8
            + Int64(sidecarChecksumBytes)
        guard total > 0, total <= maximumSidecarBytes, total <= Int64(Int.max) else { return nil }
        return Int(total)
    }

    static func requiredSignature(for term: String) -> [UInt64]? {
        var signature = [UInt64](repeating: 0, count: 4)
        addTrigrams(from: term, to: &signature, base: 0)
        return signature.contains(where: { $0 != 0 }) ? signature : nil
    }

    static func requiredShortSignature(for term: String) -> [UInt64]? {
        var signature = [UInt64](repeating: 0, count: 4)
        addShortNGrams(from: term, to: &signature, base: 0)
        return signature.contains(where: { $0 != 0 }) ? signature : nil
    }

    func blockMayContain(_ required: [UInt64], block: Int) -> Bool {
        let base = block * 4
        for lane in 0..<4 where blockSignatures.value(at: base + lane) & required[lane] != required[lane] {
            return false
        }
        return true
    }

    func blockMayContainShort(_ required: [UInt64], block: Int) -> Bool {
        let base = block * 4
        for lane in 0..<4 where shortBlockSignatures.value(at: base + lane) & required[lane] != required[lane] {
            return false
        }
        return true
    }

    /// Returns candidate name groups in their original index order. `nil`
    /// means that no trigram signature is available and callers should retain
    /// their complete scan (for example, a Unicode-only or short query).
    func candidateGroups(for required: [UInt64]) -> [Int]? {
        guard required.count >= 4, groupBitsetWordCount > 0 else {
            return nil
        }

        var intersection = [UInt64](
            repeating: UInt64.max,
            count: groupBitsetWordCount
        )
        var hasRequiredBit = false

        for lane in 0..<4 {
            var requiredBits = required[lane]
            while requiredBits != 0 {
                let bit = (lane * 64) + requiredBits.trailingZeroBitCount
                let source = bit * groupBitsetWordCount
                if !hasRequiredBit {
                    for word in 0..<groupBitsetWordCount {
                        intersection[word] = groupPresence.value(at: source + word)
                    }
                    hasRequiredBit = true
                } else {
                    for word in 0..<groupBitsetWordCount {
                        intersection[word] &= groupPresence.value(at: source + word)
                    }
                }
                requiredBits &= requiredBits &- 1
            }
        }

        guard hasRequiredBit else { return nil }
        let remainder = nameCount % 64
        if remainder != 0 {
            intersection[intersection.count - 1] &=
                (UInt64(1) << UInt64(remainder)) &- 1
        }

        var groups: [Int] = []
        groups.reserveCapacity(min(nameCount, 256))
        for wordIndex in intersection.indices {
            var bits = intersection[wordIndex]
            while bits != 0 {
                groups.append(
                    (wordIndex * 64) + bits.trailingZeroBitCount
                )
                bits &= bits &- 1
            }
        }
        return groups
    }

    /// Name groups are stored in first-seen order, so expanding all groups can
    /// interleave later duplicate nodes ahead of their original index order.
    /// Restrict posting acceleration to selective queries whose final ranking
    /// can cheaply use the durable node ID as a stable tie break. Short or very
    /// broad terms retain the complete linear scan and therefore never change
    /// order when this optional sidecar becomes ready in the background.
    func stableCandidateGroups(for term: String?) -> [Int]? {
        guard let term,
              term.utf8.count >= 3,
              let required = Self.requiredSignature(for: term),
              let groups = candidateGroups(for: required) else { return nil }

        var candidateNodes = 0
        for group in groups {
            candidateNodes += postingRange(for: group).count
            if candidateNodes > Self.maximumStableCandidateNodes { return nil }
        }
        return groups
    }

    private static func addTrigrams(from text: String, to signature: inout [UInt64], base: Int) {
        var first: UInt8?
        var second: UInt8?
        for rawByte in text.utf8 {
            guard rawByte < 0x80 else {
                first = nil
                second = nil
                continue
            }
            let byte = asciiLowercased(rawByte)
            if let a = first, let b = second {
                let hash = (UInt32(a) &* 16_777_619)
                    ^ (UInt32(b) &* 2_166_136_261)
                    ^ UInt32(byte)
                let bit = Int(hash & 255)
                signature[base + bit / 64] |= UInt64(1) << UInt64(bit % 64)
                first = b
                second = byte
            } else if first == nil {
                first = byte
            } else {
                second = byte
            }
        }
    }

    private static func addShortNGrams(from text: String, to signature: inout [UInt64], base: Int) {
        var previous: UInt8?
        for rawByte in text.utf8 {
            guard rawByte < 0x80 else {
                previous = nil
                continue
            }
            let byte = asciiLowercased(rawByte)
            let characterHash = UInt32(byte) &* 16_777_619
            let characterBit = Int(characterHash & 255)
            signature[base + characterBit / 64] |= UInt64(1) << UInt64(characterBit % 64)
            if let previous {
                let bigramHash = (UInt32(previous) &* 16_777_619) ^ (UInt32(byte) &* 2_166_136_261)
                let bigramBit = Int(bigramHash & 255)
                signature[base + bigramBit / 64] |= UInt64(1) << UInt64(bigramBit % 64)
            }
            previous = byte
        }
    }

    private static func asciiLowercased(_ byte: UInt8) -> UInt8 {
        (65...90).contains(byte) ? byte + 32 : byte
    }
}

/// Shares one lossless name-index build across the cached base and every
/// overlay snapshot. Cache loading can publish its complete node set first and
/// prewarm this structure in the background; an immediate query uses the full
/// linear node scan until the optional accelerator is ready.
fileprivate final class SearchNameIndexCache: @unchecked Sendable {
    private let nodes: [IndexedFileNode]
    private let persistBuiltIndex: (@Sendable (SearchNameIndex) -> Void)?
    private let condition = NSCondition()
    private var index: SearchNameIndex?
    private var isBuilding = false
    private var isBuilt = false

    init(
        nodes: [IndexedFileNode],
        buildImmediately: Bool,
        initialIndex: SearchNameIndex? = nil,
        persistBuiltIndex: (@Sendable (SearchNameIndex) -> Void)? = nil
    ) {
        self.nodes = nodes
        self.persistBuiltIndex = persistBuiltIndex
        if let initialIndex {
            index = initialIndex
            isBuilt = true
        } else if buildImmediately {
            index = SearchNameIndex(nodes: nodes)
            isBuilt = true
        }
    }

    func value() -> SearchNameIndex? {
        condition.lock()
        while isBuilding, !isBuilt {
            condition.wait()
        }
        if isBuilt {
            let value = index
            condition.unlock()
            return value
        }
        isBuilding = true
        condition.unlock()

        let built = SearchNameIndex(nodes: nodes)
        finish(built)
        return built
    }

    func prewarm() {
        condition.lock()
        guard !isBuilt, !isBuilding else {
            condition.unlock()
            return
        }
        isBuilding = true
        condition.unlock()
        Task.detached(priority: .background) { [self] in
            // Let an immediate launch-time query use the complete linear
            // fallback before optional posting construction consumes CPU and
            // memory. Once a search starts, remain behind the foreground gate.
            try? await Task.sleep(for: .seconds(5))
            SearchWorkCoordinator.shared.waitForSearchesToFinish()
            finish(SearchNameIndex(nodes: nodes, yieldsToForegroundSearches: true))
        }
    }

    private func finish(_ built: SearchNameIndex?) {
        condition.lock()
        index = built
        isBuilt = true
        isBuilding = false
        condition.broadcast()
        condition.unlock()
        if let built, let persistBuiltIndex {
            Task.detached(priority: .utility) {
                persistBuiltIndex(built)
            }
        }
    }

    func readyValue() -> SearchNameIndex? {
        condition.lock()
        let value = isBuilt ? index : nil
        condition.unlock()
        return value
    }
}

/// Resolves whether a base-index node is hidden by a live subtree replacement.
///
/// Name-index hits arrive in name order rather than tree order. Walking an
/// absolute path back to `/` for every hit makes a broad query pathologically
/// expensive once the event journal contains many subtree replacements. This
/// resolver follows compact parent indices instead and memoizes the active
/// replacement for every ancestor it touches. Preserved holes restore the
/// replacement that was active outside the partial subtree, matching
/// `activeReplacementRoot(for:)` without repeated NSString path surgery.
private struct BaseReplacementCoverageResolver {
    private static let unknown = Int32.min
    private static let none: Int32 = -1

    private var activeReplacementByNode: [Int32]
    private let replacementIDByRoot: [String: Int32]
    private let preservedOwnerIDsByRoot: [String: [Int32]]
    private let relevantLeafNames: Set<String>
    private var fallbackByReplacementID: [Int32]
    private var chain: [Int] = []

    init(replacements: [SearchIndexReplacement], nodeCount: Int) {
        activeReplacementByNode = replacements.isEmpty
            ? []
            : Array(repeating: Self.unknown, count: nodeCount)

        var replacementIDs: [String: Int32] = [:]
        replacementIDs.reserveCapacity(replacements.count)
        var preservedOwners: [String: [Int32]] = [:]
        var leafNames = Set<String>()
        leafNames.reserveCapacity(replacements.count * 2)

        for (offset, replacement) in replacements.enumerated() {
            guard offset < Int(Int32.max) else { break }
            let replacementID = Int32(offset)
            let root = SearchPath.canonicalAliasPath(replacement.rootPath)
            replacementIDs[root] = replacementID
            leafNames.insert(Self.leafName(of: root))
            for preservedRoot in replacement.preservedBaseRoots {
                let canonicalRoot = SearchPath.canonicalAliasPath(preservedRoot)
                preservedOwners[canonicalRoot, default: []].append(replacementID)
                leafNames.insert(Self.leafName(of: canonicalRoot))
            }
        }

        replacementIDByRoot = replacementIDs
        preservedOwnerIDsByRoot = preservedOwners
        relevantLeafNames = leafNames
        fallbackByReplacementID = Array(repeating: Self.none, count: replacements.count)
    }

    mutating func isCovered(
        index: Int,
        nodes: [IndexedFileNode],
        pathProvider: SearchIndexPathProvider
    ) -> Bool {
        guard !replacementIDByRoot.isEmpty,
              index >= 0,
              index < nodes.count else { return false }
        let cached = activeReplacementByNode[index]
        if cached != Self.unknown { return cached >= 0 }

        chain.removeAll(keepingCapacity: true)
        if chain.capacity < 8 { chain.reserveCapacity(8) }
        var current = index
        var activeReplacement = Self.none

        while current >= 0, current < nodes.count {
            let cached = activeReplacementByNode[current]
            if cached != Self.unknown {
                activeReplacement = cached
                break
            }
            chain.append(current)
            let parent = Int(nodes[current].parentIndex)
            if parent < 0 || parent >= nodes.count || parent == current {
                break
            }
            current = parent
            if chain.count > 512 { return false }
        }

        for nodeIndex in chain.reversed() {
            let node = nodes[nodeIndex]
            let shortName = node.name.hasPrefix("/")
                ? (node.name as NSString).lastPathComponent
                : node.name
            if relevantLeafNames.contains(shortName) {
                let path = SearchPath.canonicalIndexedPath(
                    pathProvider.path(for: Int32(nodeIndex))
                )
                if activeReplacement >= 0,
                   preservedOwnerIDsByRoot[path]?.contains(activeReplacement) == true {
                    activeReplacement = fallbackByReplacementID[Int(activeReplacement)]
                }
                if let replacementID = replacementIDByRoot[path] {
                    fallbackByReplacementID[Int(replacementID)] = activeReplacement
                    activeReplacement = replacementID
                }
            }
            activeReplacementByNode[nodeIndex] = activeReplacement
        }

        return activeReplacementByNode[index] >= 0
    }

    mutating func materializedCoverage(
        nodes: [IndexedFileNode],
        pathProvider: SearchIndexPathProvider
    ) -> [Int32] {
        guard !activeReplacementByNode.isEmpty else { return [] }
        // Parent indices precede their descendants in every accepted durable
        // index. Walking tree order makes each lookup inherit an already-known
        // parent state instead of rediscovering ancestor chains in name order.
        for index in nodes.indices {
            _ = isCovered(index: index, nodes: nodes, pathProvider: pathProvider)
        }
        return activeReplacementByNode
    }

    private static func leafName(of path: String) -> String {
        path == "/" ? "/" : (path as NSString).lastPathComponent
    }
}

/// One overlay coverage table is shared by every query against that immutable
/// snapshot. Exact-file events do not change subtree ownership, so the store
/// can also reuse it while rebuilding only the exact overlay layer.
fileprivate final class BaseReplacementCoverageCache: @unchecked Sendable {
    private struct Descriptor: Equatable {
        let rootPath: String
        let preservedBaseRoots: [String]
    }

    private let descriptors: [Descriptor]
    private let nodes: [IndexedFileNode]
    private let pathProvider: SearchIndexPathProvider
    private let replacements: [SearchIndexReplacement]
    private let lock = NSLock()
    private var cachedCoverage: [Int32]?

    init(
        replacements: [SearchIndexReplacement],
        nodes: [IndexedFileNode],
        pathProvider: SearchIndexPathProvider
    ) {
        descriptors = Self.descriptors(for: replacements)
        self.replacements = replacements
        self.nodes = nodes
        self.pathProvider = pathProvider
    }

    func matches(_ replacements: [SearchIndexReplacement]) -> Bool {
        descriptors == Self.descriptors(for: replacements)
    }

    func coverage() -> [Int32] {
        lock.lock()
        defer { lock.unlock() }
        if let cachedCoverage { return cachedCoverage }
        var resolver = BaseReplacementCoverageResolver(
            replacements: replacements,
            nodeCount: nodes.count
        )
        let coverage = resolver.materializedCoverage(
            nodes: nodes,
            pathProvider: pathProvider
        )
        cachedCoverage = coverage
        return coverage
    }

    func existingCoverage() -> [Int32]? {
        lock.lock()
        defer { lock.unlock() }
        return cachedCoverage
    }

    private static func descriptors(
        for replacements: [SearchIndexReplacement]
    ) -> [Descriptor] {
        replacements.map {
            Descriptor(
                rootPath: $0.rootPath,
                preservedBaseRoots: $0.preservedBaseRoots
            )
        }
    }
}

/// Compact prefix lookup for the small set of paths whose cached existence is
/// temporarily uncertain. Linear prefix checks are cheapest for a handful of
/// retry roots; a byte trie prevents a large restored event journal from
/// multiplying every broad result by hundreds of String comparisons.
private struct SearchPathPrefixIndex: Sendable {
    private struct Node: Sendable {
        var children: [UInt8: Int] = [:]
        var isTerminal = false
    }

    private let roots: [String]
    private let trie: [Node]?
    private let coversRoot: Bool

    init(roots: [String]) {
        self.roots = roots
        coversRoot = roots.contains("/")
        guard roots.count > 8, !coversRoot else {
            trie = nil
            return
        }

        var nodes = [Node()]
        for root in roots {
            var nodeIndex = 0
            for byte in root.utf8 {
                if let existing = nodes[nodeIndex].children[byte] {
                    nodeIndex = existing
                } else {
                    let next = nodes.count
                    nodes.append(Node())
                    nodes[nodeIndex].children[byte] = next
                    nodeIndex = next
                }
            }
            nodes[nodeIndex].isTerminal = true
        }
        trie = nodes
    }

    var isEmpty: Bool { roots.isEmpty }

    func contains(_ path: String) -> Bool {
        if coversRoot { return path.hasPrefix("/") }
        guard let trie else {
            return roots.contains { SearchPath.hasNormalizedPrefix(path, of: $0) }
        }

        var nodeIndex = 0
        var matchedTerminal = false
        for byte in path.utf8 {
            if matchedTerminal, byte == UInt8(ascii: "/") { return true }
            guard let next = trie[nodeIndex].children[byte] else { return false }
            nodeIndex = next
            matchedTerminal = trie[nodeIndex].isTerminal
        }
        return matchedTerminal
    }
}

/// Incrementally maintained lookup for exact-file overlays. Copying these
/// sets into an immutable search snapshot is O(1) thanks to copy-on-write;
/// rebuilding them from tens of thousands of event records on every query is
/// not. Leaf-name reference counts keep removals exact without rescanning the
/// remaining paths.
struct ExactReplacementLookup: Sendable {
    fileprivate private(set) var paths = Set<String>()
    fileprivate private(set) var leafNames = Set<String>()
    private var leafNameCounts: [String: Int] = [:]

    init(replacements: [SearchIndexExactReplacement] = []) {
        paths.reserveCapacity(replacements.count)
        leafNameCounts.reserveCapacity(replacements.count)
        for replacement in replacements {
            insert(replacement.path)
        }
    }

    mutating func insert(_ path: String) {
        guard paths.insert(path).inserted else { return }
        let leafName = Self.leafName(of: path)
        leafNameCounts[leafName, default: 0] += 1
        leafNames.insert(leafName)
    }

    mutating func remove(_ path: String) {
        guard paths.remove(path) != nil else { return }
        let leafName = Self.leafName(of: path)
        guard let count = leafNameCounts[leafName] else { return }
        if count <= 1 {
            leafNameCounts.removeValue(forKey: leafName)
            leafNames.remove(leafName)
        } else {
            leafNameCounts[leafName] = count - 1
        }
    }

    mutating func removeAll() {
        paths.removeAll(keepingCapacity: false)
        leafNames.removeAll(keepingCapacity: false)
        leafNameCounts.removeAll(keepingCapacity: false)
    }

    private static func leafName(of path: String) -> String {
        path == "/" ? "/" : (path as NSString).lastPathComponent
    }
}

struct SearchIndex: Sendable {
    let signature: SearchIndexSignature
    let nodes: [IndexedFileNode]
    let lastEventID: UInt64?
    /// `false` identifies the first, query-ready topology stage. Names, paths,
    /// node kinds, hidden state, and package ancestry are authoritative, while
    /// size and timestamps are placeholders until background enrichment lands.
    let hasCompleteMetadata: Bool
    /// A complete scan has already obtained metadata for every node.  While
    /// the filesystem event journal has no pending invalidation, querying that
    /// snapshot does not need one extra lstat per result.  The store revokes
    /// this bit as soon as an event arrives. After a partial refresh completes,
    /// only its explicitly unresolved roots require existence validation.
    let pathsAreFresh: Bool
    /// The durable builder canonicalizes and deduplicates base paths once.
    /// FSEvents can make existence stale, but they do not make that immutable
    /// base suddenly contain aliases; keep these two invariants separate so a
    /// pending event does not force every broad hit to rebuild its path.
    private let basePathsAreCanonicalUnique: Bool
    private let existenceValidationRoots: [String]
    private let existenceValidationIndex: SearchPathPrefixIndex
    /// Prefixes that could not be enumerated while this durable base was built.
    /// They are retried on every launch instead of being silently treated as empty.
    let unresolvedPaths: [String]
    let replacements: [SearchIndexReplacement]
    let exactReplacements: [SearchIndexExactReplacement]
    private let fileCount: Int
    private let directoryCount: Int
    private let replacementsByRoot: [String: SearchIndexReplacement]
    private let preservedRootsByReplacement: [String: Set<String>]
    /// Most event replacements are disjoint, complete subtrees. Their nodes
    /// are unconditionally owned by that replacement, so walking every result
    /// path back to `/` only repeats work. Keep the expensive ownership check
    /// for partial replacements and parents that actually have nested overlays.
    private let replacementRootsRequiringOwnershipCheck: Set<String>
    private let exactReplacementLookup: ExactReplacementLookup
    private let exactReplacementPaths: Set<String>
    private let exactReplacementLeafNames: Set<String>
    private let nameIndexCache: SearchNameIndexCache?
    private let pathProvider: SearchIndexPathProvider
    fileprivate let replacementCoverageCache: BaseReplacementCoverageCache

    init(
        signature: SearchIndexSignature,
        nodes: [IndexedFileNode],
        lastEventID: UInt64? = nil,
        unresolvedPaths: [String] = [],
        replacements: [SearchIndexReplacement] = [],
        exactReplacements: [SearchIndexExactReplacement] = [],
        pathsAreFresh: Bool = false,
        hasCompleteMetadata: Bool = true,
        existenceValidationRoots: [String] = [],
        buildNameIndex: Bool = true,
        deferNameIndexBuild: Bool = false,
        initialNameIndex: SearchNameIndex? = nil,
        persistBuiltNameIndex: (@Sendable (SearchNameIndex) -> Void)? = nil,
        basePathsAreCanonicalUnique: Bool? = nil
    ) {
        self.signature = signature
        self.nodes = nodes
        self.lastEventID = lastEventID
        self.pathsAreFresh = pathsAreFresh
        self.hasCompleteMetadata = hasCompleteMetadata
        self.basePathsAreCanonicalUnique = basePathsAreCanonicalUnique ?? pathsAreFresh
        self.existenceValidationRoots = Self.collapsedValidationRoots(existenceValidationRoots)
        existenceValidationIndex = SearchPathPrefixIndex(roots: self.existenceValidationRoots)
        self.unresolvedPaths = unresolvedPaths
        self.replacements = replacements
        self.exactReplacements = exactReplacements
        replacementsByRoot = Dictionary(uniqueKeysWithValues: replacements.map { ($0.rootPath, $0) })
        preservedRootsByReplacement = Dictionary(uniqueKeysWithValues: replacements.map {
            ($0.rootPath, Set($0.preservedBaseRoots))
        })
        replacementRootsRequiringOwnershipCheck = Self.replacementRootsRequiringOwnershipCheck(
            replacements
        )
        let exactReplacementLookup = ExactReplacementLookup(replacements: exactReplacements)
        self.exactReplacementLookup = exactReplacementLookup
        exactReplacementPaths = exactReplacementLookup.paths
        exactReplacementLeafNames = exactReplacementLookup.leafNames
        nameIndexCache = buildNameIndex
            ? SearchNameIndexCache(
                nodes: nodes,
                buildImmediately: !deferNameIndexBuild,
                initialIndex: initialNameIndex,
                persistBuiltIndex: persistBuiltNameIndex
            )
            : nil
        let pathProvider = SearchIndexPathProvider(nodes: nodes)
        self.pathProvider = pathProvider
        replacementCoverageCache = BaseReplacementCoverageCache(
            replacements: replacements,
            nodes: nodes,
            pathProvider: pathProvider
        )

        var files = 0
        var directories = 0
        for node in nodes {
            if node.isDirectory { directories += 1 } else { files += 1 }
        }
        self.fileCount = files
        self.directoryCount = directories
    }

    private init(
        base: SearchIndex,
        replacements: [SearchIndexReplacement],
        exactReplacements: [SearchIndexExactReplacement],
        pathsAreFresh: Bool? = nil,
        existenceValidationRoots: [String]? = nil,
        replacementCoverageCache: BaseReplacementCoverageCache? = nil,
        exactReplacementLookup: ExactReplacementLookup? = nil
    ) {
        signature = base.signature
        nodes = base.nodes
        lastEventID = base.lastEventID
        self.pathsAreFresh = pathsAreFresh ?? base.pathsAreFresh
        hasCompleteMetadata = base.hasCompleteMetadata
        basePathsAreCanonicalUnique = base.basePathsAreCanonicalUnique
        if let existenceValidationRoots {
            self.existenceValidationRoots = existenceValidationRoots
            existenceValidationIndex = SearchPathPrefixIndex(roots: existenceValidationRoots)
        } else {
            self.existenceValidationRoots = base.existenceValidationRoots
            existenceValidationIndex = base.existenceValidationIndex
        }
        unresolvedPaths = base.unresolvedPaths
        self.replacements = replacements
        self.exactReplacements = exactReplacements
        fileCount = base.fileCount
        directoryCount = base.directoryCount
        replacementsByRoot = Dictionary(uniqueKeysWithValues: replacements.map { ($0.rootPath, $0) })
        preservedRootsByReplacement = Dictionary(uniqueKeysWithValues: replacements.map {
            ($0.rootPath, Set($0.preservedBaseRoots))
        })
        replacementRootsRequiringOwnershipCheck = Self.replacementRootsRequiringOwnershipCheck(
            replacements
        )
        let exactReplacementLookup = exactReplacementLookup ?? base.exactReplacementLookup
        self.exactReplacementLookup = exactReplacementLookup
        exactReplacementPaths = exactReplacementLookup.paths
        exactReplacementLeafNames = exactReplacementLookup.leafNames
        nameIndexCache = base.nameIndexCache
        pathProvider = base.pathProvider
        if let replacementCoverageCache,
           replacementCoverageCache.matches(replacements) {
            self.replacementCoverageCache = replacementCoverageCache
        } else if base.replacementCoverageCache.matches(replacements) {
            self.replacementCoverageCache = base.replacementCoverageCache
        } else {
            self.replacementCoverageCache = BaseReplacementCoverageCache(
                replacements: replacements,
                nodes: nodes,
                pathProvider: pathProvider
            )
        }
    }

    func overlaying(
        replacements: [SearchIndexReplacement],
        exactReplacements: [SearchIndexExactReplacement]
    ) -> SearchIndex {
        overlaying(
            replacements: replacements,
            exactReplacements: exactReplacements,
            replacementCoverageCache: nil,
            exactReplacementLookup: ExactReplacementLookup(replacements: exactReplacements)
        )
    }

    fileprivate func overlaying(
        replacements: [SearchIndexReplacement],
        exactReplacements: [SearchIndexExactReplacement],
        replacementCoverageCache: BaseReplacementCoverageCache?,
        exactReplacementLookup: ExactReplacementLookup? = nil
    ) -> SearchIndex {
        guard !replacements.isEmpty || !exactReplacements.isEmpty else { return self }
        let overlayValidationRoots = replacements.flatMap(\.preservedBaseRoots)
            + exactReplacements.filter { !$0.isComplete }.map(\.path)
        return SearchIndex(
            base: self,
            replacements: replacements,
            exactReplacements: exactReplacements,
            pathsAreFresh: pathsAreFresh,
            existenceValidationRoots: Self.collapsedValidationRoots(
                existenceValidationRoots + overlayValidationRoots
            ),
            replacementCoverageCache: replacementCoverageCache,
            exactReplacementLookup: exactReplacementLookup
                ?? ExactReplacementLookup(replacements: exactReplacements)
        )
    }

    func withPathsAreFresh(_ fresh: Bool) -> SearchIndex {
        SearchIndex(
            base: self,
            replacements: replacements,
            exactReplacements: exactReplacements,
            pathsAreFresh: fresh,
            existenceValidationRoots: []
        )
    }

    func withExistenceValidationRoots(_ roots: [String]) -> SearchIndex {
        SearchIndex(
            base: self,
            replacements: replacements,
            exactReplacements: exactReplacements,
            pathsAreFresh: true,
            existenceValidationRoots: Self.collapsedValidationRoots(roots)
        )
    }

    var requiresAnyExistenceValidation: Bool {
        !pathsAreFresh || !existenceValidationIndex.isEmpty
    }

    func requiresExistenceValidation(for path: String) -> Bool {
        guard pathsAreFresh else { return true }
        return existenceValidationIndex.contains(path)
    }

    private static func collapsedValidationRoots(_ roots: [String]) -> [String] {
        let sorted = Set(roots.map(SearchPath.canonicalAliasPath))
            .map { String(decoding: $0.utf8, as: UTF8.self) }
            .sorted { lhs, rhs in
            let leftDepth = lhs.utf8.reduce(into: 0) { count, byte in
                if byte == UInt8(ascii: "/") { count += 1 }
            }
            let rightDepth = rhs.utf8.reduce(into: 0) { count, byte in
                if byte == UInt8(ascii: "/") { count += 1 }
            }
            return leftDepth == rightDepth ? lhs < rhs : leftDepth < rightDepth
        }
        var selected: [String] = []
        var selectedSet = Set<String>()
        selectedSet.reserveCapacity(sorted.count)
        for root in sorted {
            var ancestor = root
            var isCovered = false
            while ancestor != "/" {
                ancestor = SearchPath.parent(ofCanonicalPath: ancestor)
                if selectedSet.contains(ancestor) {
                    isCovered = true
                    break
                }
            }
            guard !isCovered else { continue }
            selected.append(root)
            selectedSet.insert(root)
        }
        return selected
    }

    var stats: SearchIndexStats {
        SearchIndexStats(
            indexedFiles: fileCount,
            indexedDirectories: directoryCount,
            processedEvents: 0,
            unavailablePaths: unresolvedPaths.count,
            isIndexing: false,
            loadedFromDisk: false
        )
    }

    func path(for index: Int) -> String {
        guard index >= 0 && index < nodes.count else { return "" }
        return pathProvider.path(for: Int32(index))
    }

    func prewarmNameIndex() {
        nameIndexCache?.prewarm()
    }

    var usesPersistedMappedNameIndex: Bool {
        nameIndexCache?.readyValue()?.isMapped == true
    }

    fileprivate func nameIndexForPersistence() -> SearchNameIndex? {
        nameIndexCache?.value()
    }

    func backgroundContentCandidates(
        in range: Range<Int>,
        maxFileSize: Int64,
        tier: BackgroundContentTier
    ) -> [ResolvedNode] {
        let lowerBound = max(0, range.lowerBound)
        let upperBound = min(nodes.count, range.upperBound)
        guard lowerBound < upperBound else { return [] }
        var candidates: [ResolvedNode] = []
        candidates.reserveCapacity((upperBound - lowerBound) / 4)
        for index in lowerBound..<upperBound {
            let node = nodes[index]
            let name = node.name.hasPrefix("/")
                ? (node.name as NSString).lastPathComponent
                : node.name
            let path = pathProvider.path(for: Int32(index))
            guard DocumentTextExtractor.backgroundIndexTier(
                name: name,
                path: path,
                isDirectory: node.isDirectory,
                size: node.size
            ) == tier else { continue }
            guard node.isDirectory || maxFileSize == 0 || node.size <= maxFileSize else { continue }
            candidates.append(ResolvedNode(node: node, path: path))
        }
        return candidates
    }

    /// Lossless fast path for the common literal name query. Matching still
    /// evaluates every distinct filename and retains every posting, but the
    /// completed snapshot stores four-byte node references instead of one
    /// reference-counted `ResolvedNode` value per hit.
    func compactNameMatches(
        query: CompiledSearchQuery,
        options: SearchOptions,
        limit: Int? = nil,
        usageSnapshot: SearchUsageSnapshot? = nil
    ) -> SearchIndexCompactNameMatches? {
        guard query.isSimpleNameSubstring(options: options),
              nodes.count <= Int(Int32.max) else { return nil }
        if let limit, limit <= 0 {
            return SearchIndexCompactNameMatches(
                references: [], overlayNodes: [], pathProvider: pathProvider
            )
        }

        let nameIndex = nameIndexCache?.readyValue()
        var references: [Int32] = []
        references.reserveCapacity(min(nodes.count, 250_000))
        var overlayNodes: [ResolvedNode] = []
        var rankingScores: [UInt8] = []
        rankingScores.reserveCapacity(min(nodes.count, 250_000))
        var seenPaths = Set<String>()
        let pinyin = query.matchesPinyin
        let deduplicateBasePaths = !basePathsAreCanonicalUnique
        let shouldMaterializeFullCoverage = query.plan.plainTerms[0].utf8.count == 1
        let baseReplacementCoverage = replacementCoverageCache.existingCoverage()
            ?? (shouldMaterializeFullCoverage ? replacementCoverageCache.coverage() : nil)
        var replacementCoverageResolver = baseReplacementCoverage == nil
            ? BaseReplacementCoverageResolver(replacements: replacements, nodeCount: nodes.count)
            : nil
        var encodingFailed = false

        @inline(__always)
        func score(for name: String) -> UInt8? {
            query.simpleNameSubstringMatchScoreAssumingSimple(
                name,
                options: options,
                matchesPinyin: pinyin
            )
        }

        func reachedLimit() -> Bool {
            limit.map { references.count >= $0 } ?? false
        }

        func appendBase(index: Int, shortName: String, rank: UInt8) {
            let node = nodes[index]
            if let baseReplacementCoverage {
                guard baseReplacementCoverage.isEmpty
                    || baseReplacementCoverage[index] < 0 else { return }
            } else if replacementCoverageResolver?.isCovered(
                index: index,
                nodes: nodes,
                pathProvider: pathProvider
            ) == true {
                return
            }

            var resolvedPath: String?
            if exactReplacementLeafNames.contains(shortName) {
                let path = SearchPath.canonicalIndexedPath(
                    pathProvider.path(for: Int32(index))
                )
                guard !exactReplacementPaths.contains(path) else { return }
                resolvedPath = path
            }
            guard node.isVisible(with: options) else { return }
            if deduplicateBasePaths {
                let path = resolvedPath ?? SearchPath.canonicalIndexedPath(
                    pathProvider.path(for: Int32(index))
                )
                guard seenPaths.insert(path).inserted else { return }
            }
            references.append(Int32(index))
            rankingScores.append(rank)
        }

        func appendOverlay(_ resolved: ResolvedNode, rank: UInt8) {
            guard let reference = SearchIndexCompactNameMatches.overlayReference(
                for: overlayNodes.count
            ) else {
                encodingFailed = true
                return
            }
            overlayNodes.append(resolved)
            references.append(reference)
            rankingScores.append(rank)
        }

        func appendReplacement(
            _ tempNode: TempNode,
            shortName: String,
            replacementRoot: String,
            requiresOwnershipCheck: Bool,
            rank: UInt8
        ) {
            let resolved = tempNode.resolvedNode
            let canonicalPath = SearchPath.canonicalIndexedPath(resolved.path)
            if requiresOwnershipCheck {
                guard activeReplacementRoot(
                    for: canonicalPath,
                    replacementsByRoot: replacementsByRoot,
                    preservedRootsByReplacement: preservedRootsByReplacement
                ) == replacementRoot else { return }
            }
            guard !exactReplacementPaths.contains(canonicalPath),
                  resolved.node.isVisible(with: options),
                  seenPaths.insert(canonicalPath).inserted else { return }
            appendOverlay(resolved, rank: rank)
        }

        func rankedSnapshot() -> SearchIndexCompactNameMatches? {
            guard !encodingFailed else { return nil }
            let ordered = SearchRanking.sortedCompactByRelevance(
                references,
                overlayNodes: overlayNodes,
                pathProvider: pathProvider,
                precomputedScores: rankingScores,
                query: query,
                options: options,
                usageSnapshot: usageSnapshot
            )
            return SearchIndexCompactNameMatches(
                references: ordered,
                overlayNodes: overlayNodes,
                pathProvider: pathProvider
            )
        }

        if let nameIndex,
           let groups = nameIndex.stableCandidateGroups(
               for: query.requiredNameIndexTerm(options: options)
           ) {
            for group in groups {
                if group.isMultiple(of: 4_096), Task.isCancelled { return nil }
                let shortName = nameIndex.name(at: group)
                guard let rank = score(for: shortName) else { continue }
                for position in nameIndex.postingRange(for: group) {
                    if position.isMultiple(of: 4_096), Task.isCancelled { return nil }
                    appendBase(
                        index: nameIndex.nodeIndex(at: position),
                        shortName: shortName,
                        rank: rank
                    )
                    if reachedLimit() { return rankedSnapshot() }
                }
            }
        } else {
            for index in nodes.indices {
                if index.isMultiple(of: 4_096), Task.isCancelled { return nil }
                let name = nodes[index].name
                let shortName = name.hasPrefix("/")
                    ? (name as NSString).lastPathComponent
                    : name
                guard let rank = score(for: shortName) else { continue }
                appendBase(index: index, shortName: shortName, rank: rank)
                if reachedLimit() { return rankedSnapshot() }
            }
        }

        for replacement in replacements {
            let requiresOwnershipCheck = replacementRootsRequiringOwnershipCheck.contains(
                replacement.rootPath
            )
            if let replacementIndex = replacement.nameIndex,
               let groups = replacementIndex.stableCandidateGroups(
                   for: query.requiredNameIndexTerm(options: options)
               ) {
                for group in groups {
                    if group.isMultiple(of: 4_096), Task.isCancelled { return nil }
                    let shortName = replacementIndex.name(at: group)
                    guard let rank = score(for: shortName) else { continue }
                    for position in replacementIndex.postingRange(for: group) {
                        appendReplacement(
                            replacement.nodes[replacementIndex.nodeIndex(at: position)],
                            shortName: shortName,
                            replacementRoot: replacement.rootPath,
                            requiresOwnershipCheck: requiresOwnershipCheck,
                            rank: rank
                        )
                        if reachedLimit() { return rankedSnapshot() }
                    }
                }
            } else {
                for tempNode in replacement.nodes {
                    if Task.isCancelled { return nil }
                    guard let rank = score(for: tempNode.name) else { continue }
                    appendReplacement(
                        tempNode,
                        shortName: tempNode.name,
                        replacementRoot: replacement.rootPath,
                        requiresOwnershipCheck: requiresOwnershipCheck,
                        rank: rank
                    )
                    if reachedLimit() { return rankedSnapshot() }
                }
            }
        }

        for replacement in exactReplacements {
            if Task.isCancelled { return nil }
            guard let resolved = replacement.node?.resolvedNode,
                  let rank = score(for: resolved.name),
                  resolved.node.isVisible(with: options),
                  seenPaths.insert(resolved.path).inserted else { continue }
            appendOverlay(resolved, rank: rank)
            if reachedLimit() { return rankedSnapshot() }
        }
        return rankedSnapshot()
    }

    func nameMatches(
        query: CompiledSearchQuery,
        options: SearchOptions,
        limit: Int? = nil,
        usageSnapshot: SearchUsageSnapshot? = nil
    ) -> [ResolvedNode] {
        if let limit, limit <= 0 { return [] }
        let nameIndex = nameIndexCache?.readyValue()
        var results: [ResolvedNode] = []
        var rankingScores: [UInt8] = []
        var seenPaths = Set<String>()
        let pinyin = query.matchesPinyin
        let simpleNameSubstring = query.isSimpleNameSubstring(options: options)
        func evaluateName(_ name: String) -> (matches: Bool, score: UInt8?) {
            if simpleNameSubstring {
                guard let score = query.simpleNameSubstringMatchScoreAssumingSimple(
                    name,
                    options: options,
                    matchesPinyin: pinyin
                ) else { return (false, nil) }
                return (true, score)
            }
            return (query.matchesNameFilter(name, matchesPinyin: pinyin), nil)
        }
        func ranked(_ matches: [ResolvedNode], scores: [UInt8]) -> [ResolvedNode] {
            SearchRanking.sortedByRelevance(
                matches,
                precomputedScores: scores.count == matches.count ? scores : nil,
                query: query,
                options: options,
                usageSnapshot: usageSnapshot
            )
        }
        // Partial/untrusted snapshots can still contain canonical aliases
        // (for example /private/var and /var). A completed durable build has
        // already deduplicated those paths, so its broad-query tail can retain
        // indexed references without resolving every absolute path again.
        let deduplicateBasePaths = !basePathsAreCanonicalUnique
        let shouldMaterializeFullCoverage = simpleNameSubstring
            && query.plan.plainTerms[0].utf8.count == 1
        let baseReplacementCoverage = replacementCoverageCache.existingCoverage()
            ?? (shouldMaterializeFullCoverage ? replacementCoverageCache.coverage() : nil)
        var replacementCoverageResolver = baseReplacementCoverage == nil
            ? BaseReplacementCoverageResolver(replacements: replacements, nodeCount: nodes.count)
            : nil
        if let nameIndex,
           let groups = nameIndex.stableCandidateGroups(
               for: query.requiredNameIndexTerm(options: options)
           ) {
            for group in groups {
                if group.isMultiple(of: 4_096), Task.isCancelled { return [] }
                    let shortName = nameIndex.name(at: group)
                    let evaluation = evaluateName(shortName)
                    guard evaluation.matches else { continue }
                    for position in nameIndex.postingRange(for: group) {
                        if position.isMultiple(of: 4_096), Task.isCancelled { return [] }
                        let previousCount = results.count
                        appendBaseNameMatch(
                            at: nameIndex.nodeIndex(at: position),
                            shortName: shortName,
                            query: query,
                            options: options,
                            matchesPinyin: pinyin,
                            skipNameBranchEvaluation: simpleNameSubstring,
                            deduplicatePath: deduplicateBasePaths,
                            replacementCoverage: baseReplacementCoverage,
                            replacementCoverageResolver: &replacementCoverageResolver,
                            results: &results,
                            seenPaths: &seenPaths,
                            pathProvider: pathProvider
                        )
                        if results.count != previousCount, let score = evaluation.score {
                            rankingScores.append(score)
                        }
                        if let limit, results.count >= limit {
                            return ranked(results, scores: rankingScores)
                        }
                    }
            }
        } else {
            for i in 0..<nodes.count {
                if i.isMultiple(of: 4_096), Task.isCancelled { return [] }
                let node = nodes[i]
                let shortName = node.name.hasPrefix("/") ? (node.name as NSString).lastPathComponent : node.name
                let evaluation = evaluateName(shortName)
                guard evaluation.matches else { continue }
                let previousCount = results.count
                appendBaseNameMatch(
                    at: i,
                    shortName: shortName,
                    query: query,
                    options: options,
                    matchesPinyin: pinyin,
                    skipNameBranchEvaluation: simpleNameSubstring,
                    deduplicatePath: deduplicateBasePaths,
                    replacementCoverage: baseReplacementCoverage,
                    replacementCoverageResolver: &replacementCoverageResolver,
                    results: &results,
                    seenPaths: &seenPaths,
                    pathProvider: pathProvider
                )
                if results.count != previousCount, let score = evaluation.score {
                    rankingScores.append(score)
                }
                if let limit, results.count >= limit {
                    return ranked(results, scores: rankingScores)
                }
            }
        }
        for replacement in replacements {
            let requiresOwnershipCheck = replacementRootsRequiringOwnershipCheck.contains(
                replacement.rootPath
            )
            if let replacementIndex = replacement.nameIndex,
               let groups = replacementIndex.stableCandidateGroups(
                   for: query.requiredNameIndexTerm(options: options)
               ) {
                for group in groups {
                    if group.isMultiple(of: 4_096), Task.isCancelled { return [] }
                        let shortName = replacementIndex.name(at: group)
                        let evaluation = evaluateName(shortName)
                        guard evaluation.matches else { continue }
                        for position in replacementIndex.postingRange(for: group) {
                            let previousCount = results.count
                            appendReplacementNameMatch(
                                replacement.nodes[replacementIndex.nodeIndex(at: position)],
                                shortName: shortName,
                                replacementRoot: replacement.rootPath,
                                requiresOwnershipCheck: requiresOwnershipCheck,
                                query: query,
                                options: options,
                                matchesPinyin: pinyin,
                                skipNameBranchEvaluation: simpleNameSubstring,
                                results: &results,
                                seenPaths: &seenPaths
                            )
                            if results.count != previousCount, let score = evaluation.score {
                                rankingScores.append(score)
                            }
                            if let limit, results.count >= limit {
                                return ranked(results, scores: rankingScores)
                            }
                        }
                }
            } else {
                for tempNode in replacement.nodes {
                    if Task.isCancelled { return [] }
                    let shortName = tempNode.name
                    let evaluation = evaluateName(shortName)
                    guard evaluation.matches else { continue }
                    let previousCount = results.count
                    appendReplacementNameMatch(
                        tempNode,
                        shortName: shortName,
                        replacementRoot: replacement.rootPath,
                        requiresOwnershipCheck: requiresOwnershipCheck,
                        query: query,
                        options: options,
                        matchesPinyin: pinyin,
                        skipNameBranchEvaluation: simpleNameSubstring,
                        results: &results,
                        seenPaths: &seenPaths
                    )
                    if results.count != previousCount, let score = evaluation.score {
                        rankingScores.append(score)
                    }
                    if let limit, results.count >= limit {
                        return ranked(results, scores: rankingScores)
                    }
                }
            }
        }
        for replacement in exactReplacements {
            if Task.isCancelled { return [] }
            guard let resolved = replacement.node?.resolvedNode else { continue }
            let shortName = resolved.name
            let evaluation = evaluateName(shortName)
            guard evaluation.matches else { continue }
            if !simpleNameSubstring {
                guard query.matchesNameBranch(
                    name: shortName,
                    node: resolved.node,
                    path: resolved.path,
                    options: options,
                    matchesPinyin: pinyin
                ) else { continue }
            } else {
                guard resolved.node.isVisible(with: options) else { continue }
            }
            guard seenPaths.insert(resolved.path).inserted else { continue }
            results.append(resolved)
            if let score = evaluation.score { rankingScores.append(score) }
            if let limit, results.count >= limit {
                return ranked(results, scores: rankingScores)
            }
        }
        return ranked(results, scores: rankingScores)
    }

    private func appendBaseNameMatch(
        at index: Int,
        shortName: String,
        query: CompiledSearchQuery,
        options: SearchOptions,
        matchesPinyin: Bool,
        skipNameBranchEvaluation: Bool,
        deduplicatePath: Bool,
        replacementCoverage: [Int32]?,
        replacementCoverageResolver: inout BaseReplacementCoverageResolver?,
        results: inout [ResolvedNode],
        seenPaths: inout Set<String>,
        pathProvider: SearchIndexPathProvider
    ) {
        let node = nodes[index]
        if let replacementCoverage {
            guard replacementCoverage.isEmpty || replacementCoverage[index] < 0 else { return }
        } else {
            guard replacementCoverageResolver?.isCovered(
                index: index,
                nodes: nodes,
                pathProvider: pathProvider
            ) != true else { return }
        }

        var resolvedPath: String?
        if exactReplacementLeafNames.contains(shortName) {
            let path = SearchPath.canonicalIndexedPath(
                pathProvider.path(for: Int32(index))
            )
            guard !exactReplacementPaths.contains(path) else { return }
            resolvedPath = path
        }
        if !skipNameBranchEvaluation {
            let path = resolvedPath ?? SearchPath.canonicalIndexedPath(
                pathProvider.path(for: Int32(index))
            )
            guard query.matchesNameBranch(
                name: shortName,
                node: node,
                path: path,
                options: options,
                matchesPinyin: matchesPinyin
            ) else { return }
            resolvedPath = path
        } else {
            guard node.isVisible(with: options) else { return }
        }

        if deduplicatePath {
            let path = resolvedPath ?? SearchPath.canonicalIndexedPath(
                pathProvider.path(for: Int32(index))
            )
            guard seenPaths.insert(path).inserted else { return }
            resolvedPath = path
        }

        if let resolvedPath {
            results.append(ResolvedNode(node: node, path: resolvedPath))
        } else {
            results.append(ResolvedNode(index: index, pathProvider: pathProvider))
        }
    }

    private func appendReplacementNameMatch(
        _ tempNode: TempNode,
        shortName: String,
        replacementRoot: String,
        requiresOwnershipCheck: Bool,
        query: CompiledSearchQuery,
        options: SearchOptions,
        matchesPinyin: Bool,
        skipNameBranchEvaluation: Bool,
        results: inout [ResolvedNode],
        seenPaths: inout Set<String>
    ) {
        let resolved = tempNode.resolvedNode
        let canonicalPath = SearchPath.canonicalIndexedPath(resolved.path)
        if requiresOwnershipCheck {
            guard activeReplacementRoot(
                for: canonicalPath,
                replacementsByRoot: replacementsByRoot,
                preservedRootsByReplacement: preservedRootsByReplacement
            ) == replacementRoot else { return }
        }
        guard !exactReplacementPaths.contains(canonicalPath) else { return }
        if !skipNameBranchEvaluation {
            guard query.matchesNameBranch(
                name: shortName,
                node: resolved.node,
                path: canonicalPath,
                options: options,
                matchesPinyin: matchesPinyin
            ) else { return }
        } else {
            guard resolved.node.isVisible(with: options) else { return }
        }
        guard seenPaths.insert(canonicalPath).inserted else { return }
        results.append(ResolvedNode(node: resolved.node, path: canonicalPath))
    }

    func contentCandidates(query: CompiledSearchQuery, options: SearchOptions, excluding excludedPaths: Set<String> = []) -> [ResolvedNode] {
        var results: [ResolvedNode] = []
        var seenPaths = Set<String>()
        let pinyin = query.matchesPinyin
        for i in 0..<nodes.count {
            if i.isMultiple(of: 4_096), Task.isCancelled { return [] }
            let node = nodes[i]
            guard !node.isDirectory || DocumentTextExtractor.isContentBearingDirectory(name: node.name) else {
                continue
            }
            let nodePath = path(for: i)
            let canonicalPath = SearchPath.canonicalAliasPath(nodePath)
            guard activeReplacementRoot(
                for: canonicalPath,
                replacementsByRoot: replacementsByRoot,
                preservedRootsByReplacement: preservedRootsByReplacement
            ) == nil else { continue }
            guard !exactReplacementPaths.contains(canonicalPath) else { continue }
            guard !excludedPaths.contains(canonicalPath) else { continue }
            let shortName = node.name.hasPrefix("/") ? (node.name as NSString).lastPathComponent : node.name
            guard query.matchesContentCandidate(name: shortName, node: node, path: canonicalPath, options: options, matchesPinyin: pinyin) else { continue }
            guard seenPaths.insert(canonicalPath).inserted else { continue }
            results.append(ResolvedNode(node: node, path: canonicalPath))
        }
        for replacement in replacements {
            let requiresOwnershipCheck = replacementRootsRequiringOwnershipCheck.contains(
                replacement.rootPath
            )
            for tempNode in replacement.nodes where !tempNode.isDirectory
                || DocumentTextExtractor.isContentBearingDirectory(name: tempNode.name) {
                if Task.isCancelled { return [] }
                let resolved = tempNode.resolvedNode
                if requiresOwnershipCheck {
                    guard activeReplacementRoot(
                        for: resolved.path,
                        replacementsByRoot: replacementsByRoot,
                        preservedRootsByReplacement: preservedRootsByReplacement
                    ) == replacement.rootPath else { continue }
                }
                guard !exactReplacementPaths.contains(resolved.path) else { continue }
                guard !excludedPaths.contains(resolved.path) else { continue }
                guard query.matchesContentCandidate(
                    name: resolved.name,
                    node: resolved.node,
                    path: resolved.path,
                    options: options,
                    matchesPinyin: pinyin
                ) else { continue }
                guard seenPaths.insert(resolved.path).inserted else { continue }
                results.append(resolved)
            }
        }
        for replacement in exactReplacements {
            if Task.isCancelled { return [] }
            guard let resolved = replacement.node?.resolvedNode,
                  !resolved.isDirectory
                    || DocumentTextExtractor.isContentBearingDirectory(name: resolved.name) else { continue }
            guard !excludedPaths.contains(resolved.path) else { continue }
            guard query.matchesContentCandidate(
                name: resolved.name,
                node: resolved.node,
                path: resolved.path,
                options: options,
                matchesPinyin: pinyin
            ) else { continue }
            guard seenPaths.insert(resolved.path).inserted else { continue }
            results.append(resolved)
        }
        return results.sorted(by: SearchRanking.shallowPathOrder)
    }

    private static func replacementRootsRequiringOwnershipCheck(
        _ replacements: [SearchIndexReplacement]
    ) -> Set<String> {
        guard !replacements.isEmpty else { return [] }
        let allRoots = Set(replacements.map(\.rootPath))
        var requiringCheck = Set(replacements.lazy
            .filter { !$0.preservedBaseRoots.isEmpty }
            .map(\.rootPath))

        // This runs once when a composite snapshot is created. Walking the
        // comparatively small root set here replaces millions of per-result
        // ancestor walks during broad searches.
        for root in allRoots where root != "/" {
            var candidate = (root as NSString).deletingLastPathComponent
            if candidate.isEmpty { candidate = "/" }
            while candidate != root {
                if allRoots.contains(candidate) {
                    requiringCheck.insert(candidate)
                }
                guard candidate != "/" else { break }
                let parent = (candidate as NSString).deletingLastPathComponent
                let next = parent.isEmpty ? "/" : parent
                guard next != candidate else { break }
                candidate = next
            }
        }
        return requiringCheck
    }

    /// Finds the newest usable snapshot for `path`. A partial child scan can
    /// preserve a failed prefix; in that region we must fall through to the
    /// next outer replacement before falling all the way back to the older
    /// base index.
    private func activeReplacementRoot(
        for path: String,
        replacementsByRoot: [String: SearchIndexReplacement],
        preservedRootsByReplacement: [String: Set<String>]
    ) -> String? {
        guard !replacementsByRoot.isEmpty else { return nil }
        var candidate = path
        while true {
            if let replacement = replacementsByRoot[candidate] {
                let preserved = path != candidate
                    && SearchIndexBuilder.isPath(
                        path,
                        coveredByRootPaths: preservedRootsByReplacement[replacement.rootPath] ?? []
                    )
                if !preserved { return candidate }
            }
            guard candidate != "/" else { return nil }
            let parent = (candidate as NSString).deletingLastPathComponent
            let nextCandidate = parent.isEmpty ? "/" : parent
            guard nextCandidate != candidate else { return nil }
            candidate = nextCandidate
        }
    }

    /// Folds complete, large subtree replacements into the compact parent
    /// linked base. Keeping a multi-million-entry absolute-path overlay alive
    /// beside the base is needlessly expensive after a successful scan. This
    /// operation is lossless for complete replacements; partial replacements
    /// remain overlays so their preserved base holes keep their fallback
    /// semantics.
    func compacting(completeReplacements replacements: [SearchIndexReplacement]) -> SearchIndex {
        let complete = replacements.filter { $0.preservedBaseRoots.isEmpty }
        guard !complete.isEmpty else { return self }
        let selectedRoots = Set(SearchIndexBuilder.collapseEventPaths(
            complete.map(\.rootPath),
            signature: signature
        ))
        let selected = complete.filter { selectedRoots.contains($0.rootPath) }
        guard !selected.isEmpty else { return self }

        var rootsByLeafName: [String: Set<String>] = [:]
        rootsByLeafName.reserveCapacity(selected.count)
        for replacement in selected {
            let canonicalRoot = SearchPath.canonicalAliasPath(replacement.rootPath)
            let shortName = (canonicalRoot as NSString).lastPathComponent
            rootsByLeafName[shortName, default: []].insert(canonicalRoot)
        }

        var rootIndices = Set<Int>()
        rootIndices.reserveCapacity(selected.count)
        let nameIndex = nameIndexCache?.value()
        if let nameIndex {
            // Name groups are kept in insertion order rather
            // than sorted order. Looking up every replacement with
            // `firstIndex` made a large durable checkpoint O(roots × names).
            // Scan the name groups once and resolve paths only for matching
            // leaf names.
            for group in 0..<nameIndex.nameCount {
                let shortName = nameIndex.name(at: group)
                guard let expectedRoots = rootsByLeafName[shortName] else { continue }
                for position in nameIndex.postingRange(for: group) {
                    let index = nameIndex.nodeIndex(at: position)
                    let candidatePath = SearchPath.canonicalAliasPath(path(for: index))
                    if expectedRoots.contains(candidatePath) {
                        rootIndices.insert(index)
                    }
                }
            }
        } else {
            for index in nodes.indices {
                let nodeName = nodes[index].name.hasPrefix("/")
                    ? (nodes[index].name as NSString).lastPathComponent
                    : nodes[index].name
                guard let expectedRoots = rootsByLeafName[nodeName] else { continue }
                let candidatePath = SearchPath.canonicalAliasPath(path(for: index))
                if expectedRoots.contains(candidatePath) {
                    rootIndices.insert(index)
                }
            }
        }

        var removalState = [UInt8](repeating: 0, count: nodes.count)
        func isRemoved(_ index: Int) -> Bool {
            guard index >= 0, index < nodes.count else { return false }
            if removalState[index] == 1 { return false }
            if removalState[index] == 2 { return true }

            var chain: [Int] = []
            var current = index
            var result = false
            while current >= 0, current < nodes.count, removalState[current] == 0 {
                chain.append(current)
                if rootIndices.contains(current) {
                    result = true
                    break
                }
                let parent = Int(nodes[current].parentIndex)
                if parent < 0 || parent >= nodes.count || parent == current {
                    break
                }
                current = parent
                if chain.count > 512 {
                    // A malformed cycle is rejected during cache loading, but
                    // fail open here so compaction cannot hide unrelated data.
                    result = false
                    break
                }
            }
            if current >= 0, current < nodes.count, removalState[current] == 2 {
                result = true
            }
            for chained in chain {
                removalState[chained] = result ? 2 : 1
            }
            return result
        }

        var remappedIndices = [Int32](repeating: -1, count: nodes.count)
        var retainedCount = 0
        for index in nodes.indices where !isRemoved(index) {
            remappedIndices[index] = Int32(retainedCount)
            retainedCount += 1
        }

        var mergedNodes: [IndexedFileNode] = []
        mergedNodes.reserveCapacity(retainedCount + selected.reduce(0) { $0 + $1.nodes.count })
        for index in nodes.indices where remappedIndices[index] >= 0 {
            let old = nodes[index]
            let parentIndex: Int32
            let name: String
            if old.parentIndex >= 0,
               Int(old.parentIndex) < remappedIndices.count,
               remappedIndices[Int(old.parentIndex)] >= 0 {
                parentIndex = remappedIndices[Int(old.parentIndex)]
                name = old.name
            } else {
                parentIndex = -1
                // A retained node should normally still have its parent. If
                // a malformed/legacy snapshot leaves an orphan behind, keep
                // its absolute path instead of silently changing its meaning.
                name = old.parentIndex < 0 ? old.name : path(for: index)
            }
            mergedNodes.append(IndexedFileNode(
                name: name,
                parentIndex: parentIndex,
                isDirectory: old.isDirectory,
                size: old.size,
                modifiedTime: old.modifiedTime,
                creationTime: old.creationTime,
                isHiddenScope: old.isHiddenScope,
                isPackageDescendant: old.isPackageDescendant
            ))
        }

        for replacement in selected.sorted(by: { $0.rootPath < $1.rootPath }) {
            let offset = Int32(mergedNodes.count)
            let replacementNodes = SearchIndexBuilder.assembleIndexedNodes(from: replacement.nodes)
            mergedNodes.append(contentsOf: replacementNodes.map { node in
                IndexedFileNode(
                    name: node.name,
                    parentIndex: node.parentIndex >= 0 ? node.parentIndex + offset : -1,
                    isDirectory: node.isDirectory,
                    size: node.size,
                    modifiedTime: node.modifiedTime,
                    creationTime: node.creationTime,
                    isHiddenScope: node.isHiddenScope,
                    isPackageDescendant: node.isPackageDescendant
                )
            })
        }

        return SearchIndex(
            signature: signature,
            nodes: mergedNodes,
            lastEventID: lastEventID,
            unresolvedPaths: unresolvedPaths.filter { path in
                !selectedRoots.contains { root in
                    SearchPath.hasNormalizedPrefix(path, of: root)
                }
            },
            pathsAreFresh: pathsAreFresh,
            hasCompleteMetadata: hasCompleteMetadata,
            existenceValidationRoots: existenceValidationRoots.filter { path in
                !selectedRoots.contains { root in
                    SearchPath.hasNormalizedPrefix(path, of: root)
                }
            },
            basePathsAreCanonicalUnique: basePathsAreCanonicalUnique
        )
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
                creationTime: node.creationTime,
                isHiddenScope: node.isHiddenScope,
                isPackageDescendant: node.isPackageDescendant
            ))
        }
        return tempNodes
    }
}

enum SearchRanking {
    private static let broadResultThreshold = 100_000
    private static let broadHeadCount = 2_000

    static func sortedByRelevance(
        _ matches: [ResolvedNode],
        precomputedScores: [UInt8]? = nil,
        query: CompiledSearchQuery,
        options: SearchOptions,
        usageSnapshot: SearchUsageSnapshot? = nil
    ) -> [ResolvedNode] {
        guard let term = query.rankingTerm(options: options) else {
            guard let usageSnapshot, !usageSnapshot.isEmpty else {
                return matches.count > broadResultThreshold
                    ? matches
                    : matches.sorted(by: shallowPathOrder)
            }
            if matches.count > broadResultThreshold {
                return promotingUsedMatches(matches, usageSnapshot: usageSnapshot)
            }
            return matches.sorted { lhs, rhs in
                let order = usageOrder(
                    usageSnapshot.rank(for: lhs),
                    usageSnapshot.rank(for: rhs)
                )
                return order == 0 ? shallowPathOrder(lhs, rhs) : order < 0
            }
        }
        let needle = term.lowercased()
        let validPrecomputedScores = precomputedScores?.count == matches.count
            ? precomputedScores
            : nil
        guard matches.count > broadResultThreshold else {
            let mapped = matches
                .enumerated()
                .map { ordinal, node in
                    (
                        ordinal: ordinal,
                        node: node,
                        score: validPrecomputedScores
                            .map { Int($0[ordinal]) }
                            ?? score(name: node.name, needle: needle),
                        usage: usageSnapshot?.rank(for: node),
                        depth: node.pathDepth
                    )
                }
            let sorted = mapped.sorted { lhs, rhs in
                    if lhs.score != rhs.score { return lhs.score < rhs.score }
                    let usageOrder = usageOrder(lhs.usage, rhs.usage)
                    if usageOrder != 0 { return usageOrder < 0 }
                    if lhs.depth != rhs.depth { return lhs.depth < rhs.depth }
                    return stableNodeOrder(
                        lhs.node,
                        ordinal: lhs.ordinal,
                        before: rhs.node,
                        ordinal: rhs.ordinal
                    )
                }
                .map(\.node)
            return sorted
        }

        // Scores have only five possible values. A binary heap performed
        // O(matches × log 2,000) comparisons and repeatedly walked parent
        // chains for millions of candidates. Count score classes first, then
        // depth-bucket only the classes that can enter the visible head. This
        // produces the exact same score/depth/index order in linear time while
        // retaining the complete deterministic tail.
        let headLimit = min(broadHeadCount, matches.count)
        var scores = validPrecomputedScores ?? []
        if scores.isEmpty { scores.reserveCapacity(matches.count) }
        var scoreCounts = [Int](repeating: 0, count: 5)
        if scores.count == matches.count {
            for rank in scores { scoreCounts[Int(rank)] += 1 }
        } else {
            for node in matches {
                let rank = score(name: node.name, needle: needle)
                scores.append(UInt8(rank))
                scoreCounts[rank] += 1
            }
        }

        var remaining = headLimit
        var maximumSelectedScore = 4
        for rank in scoreCounts.indices {
            if scoreCounts[rank] >= remaining {
                maximumSelectedScore = rank
                break
            }
            remaining -= scoreCounts[rank]
        }

        let maximumDepth = 512
        let depthBucketCount = maximumDepth + 1
        var buckets = [[Int]](
            repeating: [],
            count: (maximumSelectedScore + 1) * depthBucketCount
        )
        var usedByScore = [[(ordinal: Int, usage: SearchUsageRank, depth: Int)]](
            repeating: [],
            count: maximumSelectedScore + 1
        )
        for (ordinal, node) in matches.enumerated() {
            let rank = Int(scores[ordinal])
            guard rank <= maximumSelectedScore else { continue }
            let depth = min(maximumDepth, max(0, node.pathDepth))
            let bucketIndex = rank * depthBucketCount + depth
            if buckets[bucketIndex].count < headLimit {
                buckets[bucketIndex].append(ordinal)
            }
            if let usage = usageSnapshot?.rank(for: node) {
                usedByScore[rank].append((ordinal, usage, depth))
            }
        }

        var selectedOrdinals: [Int] = []
        selectedOrdinals.reserveCapacity(headLimit)
        var selectedUsageOrdinals = Set<Int>()
        for rank in 0...maximumSelectedScore {
            usedByScore[rank].sort { lhs, rhs in
                let order = usageOrder(lhs.usage, rhs.usage)
                if order != 0 { return order < 0 }
                if lhs.depth != rhs.depth { return lhs.depth < rhs.depth }
                return lhs.ordinal < rhs.ordinal
            }
            for used in usedByScore[rank] where selectedOrdinals.count < headLimit {
                selectedOrdinals.append(used.ordinal)
                selectedUsageOrdinals.insert(used.ordinal)
            }
            for depth in 0...maximumDepth {
                let bucket = buckets[rank * depthBucketCount + depth]
                let needed = headLimit - selectedOrdinals.count
                guard needed > 0 else { break }
                for ordinal in bucket where !selectedUsageOrdinals.contains(ordinal) {
                    selectedOrdinals.append(ordinal)
                    if selectedOrdinals.count == headLimit { break }
                }
            }
            if selectedOrdinals.count == headLimit { break }
        }

        let selectedSet = Set(selectedOrdinals)
        var output = selectedOrdinals.map { matches[$0] }
        output.reserveCapacity(matches.count)
        for (ordinal, node) in matches.enumerated() where !selectedSet.contains(ordinal) {
            output.append(node)
        }
        return output
    }

    static func sortedCompactByRelevance(
        _ references: [Int32],
        overlayNodes: [ResolvedNode],
        pathProvider: SearchIndexPathProvider,
        precomputedScores: [UInt8],
        query: CompiledSearchQuery,
        options: SearchOptions,
        usageSnapshot: SearchUsageSnapshot? = nil
    ) -> [Int32] {
        guard !references.isEmpty else { return [] }

        @inline(__always)
        func node(for reference: Int32) -> ResolvedNode {
            if reference >= 0 {
                return ResolvedNode(index: Int(reference), pathProvider: pathProvider)
            }
            return overlayNodes[Int(-1 - Int64(reference))]
        }

        guard let term = query.rankingTerm(options: options) else {
            guard let usageSnapshot, !usageSnapshot.isEmpty else {
                if references.count > broadResultThreshold { return references }
                return references.sorted {
                    shallowPathOrder(node(for: $0), node(for: $1))
                }
            }
            if references.count > broadResultThreshold {
                var used: [
                    (ordinal: Int, reference: Int32, usage: SearchUsageRank, depth: Int)
                ] = []
                for (ordinal, reference) in references.enumerated() {
                    let resolved = node(for: reference)
                    if let usage = usageSnapshot.rank(for: resolved) {
                        used.append((ordinal, reference, usage, resolved.pathDepth))
                    }
                }
                guard !used.isEmpty else { return references }
                used.sort { lhs, rhs in
                    let order = usageOrder(lhs.usage, rhs.usage)
                    if order != 0 { return order < 0 }
                    if lhs.depth != rhs.depth { return lhs.depth < rhs.depth }
                    return stableReferenceOrder(
                        lhs.reference,
                        ordinal: lhs.ordinal,
                        before: rhs.reference,
                        ordinal: rhs.ordinal
                    )
                }
                let usedOrdinals = Set(used.map(\.ordinal))
                var output = used.map(\.reference)
                output.reserveCapacity(references.count)
                for (ordinal, reference) in references.enumerated()
                    where !usedOrdinals.contains(ordinal) {
                    output.append(reference)
                }
                return output
            }
            return references.enumerated()
                .map { ordinal, reference in
                    let resolved = node(for: reference)
                    return (
                        ordinal: ordinal,
                        reference: reference,
                        usage: usageSnapshot.rank(for: resolved),
                        depth: resolved.pathDepth
                    )
                }
                .sorted { lhs, rhs in
                    let order = usageOrder(lhs.usage, rhs.usage)
                    if order != 0 { return order < 0 }
                    if lhs.depth != rhs.depth { return lhs.depth < rhs.depth }
                    return lhs.ordinal < rhs.ordinal
                }
                .map(\.reference)
        }

        let needle = term.lowercased()
        var scores = precomputedScores.count == references.count
            ? precomputedScores
            : []
        if scores.isEmpty {
            scores.reserveCapacity(references.count)
            for reference in references {
                scores.append(UInt8(score(name: node(for: reference).name, needle: needle)))
            }
        }

        guard references.count > broadResultThreshold else {
            return references.enumerated()
                .map { ordinal, reference in
                    let resolved = node(for: reference)
                    return (
                        ordinal: ordinal,
                        reference: reference,
                        score: Int(scores[ordinal]),
                        usage: usageSnapshot?.rank(for: resolved),
                        depth: resolved.pathDepth
                    )
                }
                .sorted { lhs, rhs in
                    if lhs.score != rhs.score { return lhs.score < rhs.score }
                    let order = usageOrder(lhs.usage, rhs.usage)
                    if order != 0 { return order < 0 }
                    if lhs.depth != rhs.depth { return lhs.depth < rhs.depth }
                    return lhs.ordinal < rhs.ordinal
                }
                .map(\.reference)
        }

        let headLimit = min(broadHeadCount, references.count)
        var scoreCounts = [Int](repeating: 0, count: 5)
        for rank in scores { scoreCounts[Int(rank)] += 1 }

        var remaining = headLimit
        var maximumSelectedScore = 4
        for rank in scoreCounts.indices {
            if scoreCounts[rank] >= remaining {
                maximumSelectedScore = rank
                break
            }
            remaining -= scoreCounts[rank]
        }

        let maximumDepth = 512
        let depthBucketCount = maximumDepth + 1
        var buckets = [[Int]](
            repeating: [],
            count: (maximumSelectedScore + 1) * depthBucketCount
        )
        var usedByScore = [[(ordinal: Int, usage: SearchUsageRank, depth: Int)]](
            repeating: [],
            count: maximumSelectedScore + 1
        )
        for (ordinal, reference) in references.enumerated() {
            let rank = Int(scores[ordinal])
            guard rank <= maximumSelectedScore else { continue }
            let resolved = node(for: reference)
            let depth = min(maximumDepth, max(0, resolved.pathDepth))
            let bucketIndex = rank * depthBucketCount + depth
            if buckets[bucketIndex].count < headLimit {
                buckets[bucketIndex].append(ordinal)
            }
            if let usage = usageSnapshot?.rank(for: resolved) {
                usedByScore[rank].append((ordinal, usage, depth))
            }
        }

        var selectedOrdinals: [Int] = []
        selectedOrdinals.reserveCapacity(headLimit)
        var selectedUsageOrdinals = Set<Int>()
        for rank in 0...maximumSelectedScore {
            usedByScore[rank].sort { lhs, rhs in
                let order = usageOrder(lhs.usage, rhs.usage)
                if order != 0 { return order < 0 }
                if lhs.depth != rhs.depth { return lhs.depth < rhs.depth }
                return lhs.ordinal < rhs.ordinal
            }
            for used in usedByScore[rank] where selectedOrdinals.count < headLimit {
                selectedOrdinals.append(used.ordinal)
                selectedUsageOrdinals.insert(used.ordinal)
            }
            for depth in 0...maximumDepth {
                let bucket = buckets[rank * depthBucketCount + depth]
                guard selectedOrdinals.count < headLimit else { break }
                for ordinal in bucket where !selectedUsageOrdinals.contains(ordinal) {
                    selectedOrdinals.append(ordinal)
                    if selectedOrdinals.count == headLimit { break }
                }
            }
            if selectedOrdinals.count == headLimit { break }
        }

        let selectedSet = Set(selectedOrdinals)
        var output = selectedOrdinals.map { references[$0] }
        output.reserveCapacity(references.count)
        for (ordinal, reference) in references.enumerated()
            where !selectedSet.contains(ordinal) {
            output.append(reference)
        }
        return output
    }

    private static func promotingUsedMatches(
        _ matches: [ResolvedNode],
        usageSnapshot: SearchUsageSnapshot
    ) -> [ResolvedNode] {
        var used: [(ordinal: Int, node: ResolvedNode, usage: SearchUsageRank)] = []
        for (ordinal, node) in matches.enumerated() {
            if let usage = usageSnapshot.rank(for: node) {
                used.append((ordinal, node, usage))
            }
        }
        guard !used.isEmpty else { return matches }
        used.sort { lhs, rhs in
            let order = usageOrder(lhs.usage, rhs.usage)
            if order != 0 { return order < 0 }
            let leftDepth = lhs.node.pathDepth
            let rightDepth = rhs.node.pathDepth
            if leftDepth != rightDepth { return leftDepth < rightDepth }
            return lhs.ordinal < rhs.ordinal
        }
        let usedOrdinals = Set(used.map(\.ordinal))
        var output = used.map(\.node)
        output.reserveCapacity(matches.count)
        for (ordinal, node) in matches.enumerated() where !usedOrdinals.contains(ordinal) {
            output.append(node)
        }
        return output
    }

    /// Negative means lhs comes first. Count dominates recency; both are only
    /// consulted after semantic relevance has tied.
    private static func usageOrder(
        _ lhs: SearchUsageRank?,
        _ rhs: SearchUsageRank?
    ) -> Int {
        switch (lhs, rhs) {
        case (nil, nil):
            return 0
        case (.some, nil):
            return -1
        case (nil, .some):
            return 1
        case (.some(let lhs), .some(let rhs)):
            if lhs.openCount != rhs.openCount {
                return lhs.openCount > rhs.openCount ? -1 : 1
            }
            if lhs.lastOpened != rhs.lastOpened {
                return lhs.lastOpened > rhs.lastOpened ? -1 : 1
            }
            return 0
        }
    }

    /// Optional posting indexes can enumerate equal-name nodes together. Use
    /// the durable base-node ID instead of arrival order so the visible result
    /// order is identical before and after a background name index is ready.
    private static func stableNodeOrder(
        _ lhs: ResolvedNode,
        ordinal lhsOrdinal: Int,
        before rhs: ResolvedNode,
        ordinal rhsOrdinal: Int
    ) -> Bool {
        switch (lhs.indexedOrder, rhs.indexedOrder) {
        case (.some(let left), .some(let right)) where left != right:
            return left < right
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            return lhsOrdinal < rhsOrdinal
        }
    }

    private static func stableReferenceOrder(
        _ lhs: Int32,
        ordinal lhsOrdinal: Int,
        before rhs: Int32,
        ordinal rhsOrdinal: Int
    ) -> Bool {
        switch (lhs >= 0, rhs >= 0) {
        case (true, true) where lhs != rhs:
            return lhs < rhs
        case (true, false):
            return true
        case (false, true):
            return false
        default:
            return lhsOrdinal < rhsOrdinal
        }
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
        if (lower as NSString).deletingPathExtension == needle { return 1 }
        guard let range = lower.range(of: needle) else { return 4 }
        if range.lowerBound == lower.startIndex { return 2 }
        let before = lower[lower.index(before: range.lowerBound)]
        return (before.isLetter || before.isNumber) ? 4 : 3
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
    private let contentSearchIndex: ContentSearchIndex
    private let queryReadyBuildOperation: (@Sendable (SearchIndexSignature) async -> SearchIndexBuildResult)?
    private let buildOperation: (@Sendable (SearchIndexSignature) async -> SearchIndexBuildResult)?
    private var compositeSnapshot: SearchIndex?
    private var index: SearchIndex? {
        didSet {
            compositeSnapshot = nil
            eventReplacementCoverageCache = nil
        }
    }
    private var eventReplacements: [String: SearchIndexReplacement] = [:] {
        didSet {
            compositeSnapshot = nil
            eventReplacementCoverageCache = nil
        }
    }
    private var eventExactReplacements: [String: SearchIndexExactReplacement] = [:] {
        didSet { compositeSnapshot = nil }
    }
    private var eventExactReplacementLookup = ExactReplacementLookup()
    private var eventReplacementCoverageCache: BaseReplacementCoverageCache?
    private var currentSignature: SearchIndexSignature?
    private var currentStats = SearchIndexStats()
    private var watcher: FileSystemEventWatcher?
    private var eventLogWatcher: FileSystemEventWatcher?
    private var pendingSubtreeEventPaths = Set<String>()
    private var pendingExactEventPaths = Set<String>()
    private var pendingEventID: UInt64?
    private var latestAppliedEventID: UInt64?
    private var deferredEventCheckpointID: UInt64?
    private var pendingEventsRequireFullRebuild = false
    private var pendingChangesRequireConservativeRefresh = false
    private var unresolvedSubtreeEventPaths = Set<String>()
    private var unresolvedExactEventPaths = Set<String>()
    private var knownUnavailablePaths = Set<String>()
    private var unresolvedRetryTask: Task<Void, Never>?
    private var unresolvedRetryAttempt = 0
    private var eventRefreshTask: Task<Void, Never>?
    private var eventRefreshGeneration = 0
    private var rebuildTask: Task<SearchIndexStats, Never>?
    private var contentEnrichmentTask: Task<Void, Never>?
    private var rebuildGeneration = 0
    private var activeBuildGeneration: Int?
    private var persistTask: Task<Void, Never>?
    private var eventJournalFlushTask: Task<Void, Never>?
    private var eventJournalFlushGeneration = 0
    private var eventJournalIsDirty = false
    private var watcherRetryTask: Task<Void, Never>?
    private var watcherGeneration = 0
    private var nextExactCompactionCount = 30_000
    private var inProgressSeen = Set<String>()
    private var inProgressPathToIndex: [String: Int32] = [:]
    private var inProgressNodes: [IndexedFileNode] = []
    private var acceptsPartialBuildBatches = true
    private var lastPartialPublish: ContinuousClock.Instant?
    private let maximumPartialBuildNodes = 250_000
    /// A complete replacement this large is cheaper to merge into the compact
    /// parent-linked base than to retain as an absolute-path overlay forever.
    /// Smaller replacements stay incremental so ordinary edits remain cheap.
    private let largeSubtreeCompactionThreshold = 100_000
    private var eventLog: [FileSystemEventLogEntry] = []
    private var nextEventLogID: Int64 = 1
    private let maxEventLogEntries = 20_000
    private struct RevisionChangeBatch: Sendable {
        let revision: Int
        let changes: SearchIndexChanges
    }
    private var revisionChangeBatches: [RevisionChangeBatch] = []
    private let maxRevisionChangeBatches = 16

    init(
        persistenceURL: URL? = nil,
        queryReadyBuildOperation: (@Sendable (SearchIndexSignature) async -> SearchIndexBuildResult)? = nil,
        buildOperation: (@Sendable (SearchIndexSignature) async -> SearchIndexBuildResult)? = nil
    ) {
        self.persistenceURL = persistenceURL
        if let queryReadyBuildOperation {
            self.queryReadyBuildOperation = queryReadyBuildOperation
        } else if buildOperation == nil {
            self.queryReadyBuildOperation = { signature in
                await SearchIndexBuilder.buildQueryReadyWithDiagnostics(signature: signature)
            }
        } else {
            // Tests and callers that inject only a complete builder retain a
            // single deterministic stage unless they also inject Stage 1.
            self.queryReadyBuildOperation = nil
        }
        self.buildOperation = buildOperation
        let effectivePersistenceURL = persistenceURL ?? SearchIndexPersistence.cacheURL
        contentSearchIndex = ContentSearchIndex(
            databaseURL: ContentSearchIndex.databaseURL(for: effectivePersistenceURL),
            legacyDatabaseURL: ContentSearchIndex.legacyDatabaseURL(for: effectivePersistenceURL)
        )
    }

    func snapshot(
        for scopes: [URL],
        deepIndex: Bool = false,
        hasFullDiskAccess: Bool = SearchPermissions.hasFullDiskAccess(),
        requiringCompleteMetadata: Bool = false
    ) async -> SearchIndex {
        let signature = SearchIndexSignature(
            scopes: scopes,
            deepIndex: deepIndex,
            hasFullDiskAccess: hasFullDiskAccess
        )
        if currentSignature == signature,
           index?.signature == signature,
           let snapshot = currentSnapshot(),
           !requiringCompleteMetadata || snapshot.hasCompleteMetadata {
            return snapshot
        }

        // `loadOrRebuild` installs a durable cached base before replaying its
        // event journal. A search arriving in those few milliseconds used to
        // await the entire (potentially very large) delta replay even though a
        // complete query-ready base was already about to become available.
        // Yield the actor until that first snapshot is published; delta repair
        // remains active behind the foreground-search gate.
        if currentSignature == signature, let rebuildTask {
            if requiringCompleteMetadata {
                _ = await rebuildTask.value
            } else {
                while currentSignature == signature,
                      self.rebuildTask != nil,
                      index?.signature != signature,
                      !Task.isCancelled {
                    await Task.yield()
                    try? await Task.sleep(for: .milliseconds(5))
                }
            }
            if index?.signature == signature,
               let snapshot = currentSnapshot(),
               !requiringCompleteMetadata || snapshot.hasCompleteMetadata {
                return snapshot
            }
        }

        _ = await prepare(scopes: scopes, deepIndex: deepIndex, hasFullDiskAccess: hasFullDiskAccess)
        if index?.signature == signature,
           let snapshot = currentSnapshot(),
           !requiringCompleteMetadata || snapshot.hasCompleteMetadata {
            return snapshot
        }

        let nodes = await Task.detached(priority: .userInitiated) {
            await SearchIndexBuilder.build(signature: signature)
        }.value
        return SearchIndex(
            signature: signature,
            nodes: nodes,
            basePathsAreCanonicalUnique: true
        )
    }

    @discardableResult
    func prepare(
        scopes: [URL],
        deepIndex: Bool = false,
        hasFullDiskAccess: Bool = SearchPermissions.hasFullDiskAccess()
    ) async -> SearchIndexStats {
        let signature = SearchIndexSignature(
            scopes: scopes,
            deepIndex: deepIndex,
            hasFullDiskAccess: hasFullDiskAccess
        )
        guard !signature.scopes.isEmpty else {
            cancelPipeline()
            index = SearchIndex(signature: signature, nodes: [])
            currentSignature = signature
            currentStats = SearchIndexStats()
            return currentStats
        }

        if currentSignature == signature {
            if index?.signature == signature { return currentStats }
            if let rebuildTask { return await rebuildTask.value }
        }

        let signatureChanged = currentSignature != signature
        cancelPipeline()
        invalidateIndexFreshness()
        if signatureChanged { index = nil }
        currentSignature = signature
        currentStats = SearchIndexStats()
        return await startRebuild(signature: signature, tryCache: true)
    }

    @discardableResult
    func refresh(
        scopes: [URL],
        deepIndex: Bool = false,
        hasFullDiskAccess: Bool = SearchPermissions.hasFullDiskAccess()
    ) async -> SearchIndexStats {
        let signature = SearchIndexSignature(
            scopes: scopes,
            deepIndex: deepIndex,
            hasFullDiskAccess: hasFullDiskAccess
        )
        guard !signature.scopes.isEmpty else {
            cancelPipeline()
            index = SearchIndex(signature: signature, nodes: [])
            currentSignature = signature
            currentStats = SearchIndexStats()
            return currentStats
        }

        let signatureChanged = currentSignature != signature
        cancelPipeline()
        // A full filesystem refresh does not make unchanged file contents
        // stale. Preserve the acceleration database and let metadata
        // fingerprints plus FSEvents invalidate only files that changed.
        invalidateIndexFreshness()
        if signatureChanged { index = nil }
        currentSignature = signature
        currentStats = SearchIndexStats()
        return await startRebuild(signature: signature, tryCache: false)
    }

    func stats() -> SearchIndexStats {
        currentStats
    }

    func contentIndexHandle() -> ContentSearchIndex {
        contentSearchIndex
    }

    func observation(since revision: Int) -> SearchIndexObservation {
        let currentRevision = currentStats.indexRevision
        guard revision <= currentRevision else {
            return SearchIndexObservation(stats: currentStats, changes: nil)
        }
        guard revision < currentRevision else {
            return SearchIndexObservation(stats: currentStats, changes: .empty)
        }

        let batches = revisionChangeBatches.filter { $0.revision > revision }
        let expectedRevisions = Array((revision + 1)...currentRevision)
        guard batches.map(\.revision) == expectedRevisions else {
            return SearchIndexObservation(stats: currentStats, changes: nil)
        }

        return SearchIndexObservation(
            stats: currentStats,
            changes: SearchIndexChanges(
                subtreeReplacements: batches.flatMap { $0.changes.subtreeReplacements },
                exactReplacements: batches.flatMap { $0.changes.exactReplacements },
                requiresConservativeRefresh: batches.contains { $0.changes.requiresConservativeRefresh }
            )
        )
    }

    func recentEventLog() -> [FileSystemEventLogEntry] {
        eventLog
    }

    func unavailablePathDiagnostics() -> [String] {
        knownUnavailablePaths.sorted()
    }

    private func installExactReplacement(_ replacement: SearchIndexExactReplacement) {
        if eventExactReplacements.updateValue(replacement, forKey: replacement.path) == nil {
            eventExactReplacementLookup.insert(replacement.path)
        }
    }

    private func removeAllExactReplacements() {
        eventExactReplacements.removeAll()
        eventExactReplacementLookup.removeAll()
    }

    private func removeExactReplacements(where shouldRemove: (String) -> Bool) {
        let removedPaths = eventExactReplacements.keys.filter(shouldRemove)
        guard !removedPaths.isEmpty else { return }
        for path in removedPaths {
            eventExactReplacements.removeValue(forKey: path)
            eventExactReplacementLookup.remove(path)
        }
    }

    private func currentSnapshot() -> SearchIndex? {
        guard let currentSignature else { return nil }
        if let compositeSnapshot, compositeSnapshot.signature == currentSignature {
            return compositeSnapshot
        }
        guard let index, index.signature == currentSignature else { return nil }
        let snapshot = index.overlaying(
            replacements: eventReplacements.values.sorted { $0.rootPath < $1.rootPath },
            exactReplacements: eventExactReplacements.values.sorted { $0.path < $1.path },
            replacementCoverageCache: eventReplacementCoverageCache,
            exactReplacementLookup: eventExactReplacementLookup
        )
        eventReplacementCoverageCache = snapshot.replacementCoverageCache
        compositeSnapshot = snapshot
        return snapshot
    }

    private func invalidateIndexFreshness() {
        guard let index else { return }
        self.index = index.withPathsAreFresh(false)
    }

    /// Once every newly observed event has either been reconciled or recorded
    /// as a retry root, the rest of the index is trustworthy again. Keeping a
    /// single unavailable path in a global-stale state would force millions of
    /// unrelated results through `lstat` on every search.
    private func restoreScopedIndexFreshnessIfPossible() {
        guard let index,
              activeBuildGeneration == nil,
              pendingSubtreeEventPaths.isEmpty,
              pendingExactEventPaths.isEmpty,
              !pendingEventsRequireFullRebuild else { return }
        self.index = index.withExistenceValidationRoots(Array(knownUnavailablePaths))
    }

    func noteFileEvents(_ events: [FileSystemEvent]) {
        let visibleEvents = events.filter { $0.path != nil }
        guard !visibleEvents.isEmpty else { return }
        currentStats.processedEvents += visibleEvents.count
        for event in visibleEvents {
            eventLog.append(FileSystemEventLogEntry(
                id: nextEventLogID,
                receivedAt: event.receivedAt,
                eventID: event.eventID,
                flags: event.flags,
                path: event.path.map(SearchPath.canonicalAliasPath)
            ))
            nextEventLogID += 1
        }
        if eventLog.count > maxEventLogEntries {
            eventLog.removeFirst(eventLog.count - maxEventLogEntries)
        }
    }

    private func noteFileEvents(
        _ events: [FileSystemEvent],
        expectedSignature: SearchIndexSignature,
        watcherGeneration: Int
    ) {
        guard watcherGeneration == self.watcherGeneration,
              expectedSignature == currentSignature else { return }
        noteFileEvents(events)
    }

    private func noteIndexEvents(_ events: [FileSystemEvent]) async {
        guard !events.isEmpty else { return }
        let signature = currentSignature
        let ignoredPaths = signature.map { SearchIndexBuilder.effectiveIgnoredPaths(for: $0) }
        var sawRelevantEvent = false
        var contentExactPaths: [String] = []
        var contentSubtreePaths: [String] = []
        var invalidateAllContent = false
        for event in events {
            if let path = event.path,
               SearchIndexPersistence.isInternalIndexEvent(
                   path: path,
                   flags: event.flags,
                   baseURL: persistenceURL
               ) {
                continue
            }
            sawRelevantEvent = true
            if event.eventID > 0 {
                pendingEventID = max(pendingEventID ?? 0, event.eventID)
            }
            if event.requiresFullRescan {
                pendingEventsRequireFullRebuild = true
                invalidateAllContent = true
            }
            let flags = FSEventStreamEventFlags(event.flags)
            if event.requiresFullRescan
                || (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed)) != 0 {
                pendingChangesRequireConservativeRefresh = true
            }
            if let refresh = event.indexRefresh,
               let signature,
               let ignoredPaths {
                let refreshPath: String
                switch refresh {
                case .exact(let path):
                    refreshPath = path
                case .subtree(let path):
                    refreshPath = path
                case .directoryMetadata(let path):
                    refreshPath = path
                }
                guard signature.contains(path: refreshPath),
                      !SearchIndexBuilder.isIgnored(refreshPath, ignoredPaths: ignoredPaths) else {
                    continue
                }
                switch refresh {
                case .exact:
                    pendingExactEventPaths.insert(refreshPath)
                    contentExactPaths.append(refreshPath)
                case .subtree:
                    pendingSubtreeEventPaths.insert(refreshPath)
                    contentSubtreePaths.append(refreshPath)
                case .directoryMetadata:
                    switch Self.resolvedDirectoryMetadataRefresh(
                        path: refreshPath,
                        knownUnavailablePaths: knownUnavailablePaths
                    ) {
                    case .exact(let path):
                        pendingExactEventPaths.insert(path)
                        contentExactPaths.append(path)
                    case .subtree(let path):
                        pendingSubtreeEventPaths.insert(path)
                        contentSubtreePaths.append(path)
                    case .directoryMetadata:
                        assertionFailure("Directory metadata refresh must resolve to exact or subtree")
                    }
                }
            }
        }
        if sawRelevantEvent {
            invalidateIndexFreshness()
        }
        if invalidateAllContent {
            await contentSearchIndex.invalidateAll()
        } else if !contentExactPaths.isEmpty || !contentSubtreePaths.isEmpty {
            await contentSearchIndex.invalidate(
                exactPaths: contentExactPaths,
                subtreePaths: contentSubtreePaths
            )
        }
        scheduleEventRefresh()
    }

    static func resolvedDirectoryMetadataRefresh(
        path: String,
        knownUnavailablePaths: Set<String>
    ) -> FileSystemIndexRefresh {
        let canonicalPath = SearchPath.canonicalAliasPath(path)
        let overlapsUnavailablePath = knownUnavailablePaths.contains { unavailablePath in
            SearchPath.hasNormalizedPrefix(unavailablePath, of: canonicalPath)
                || SearchPath.hasNormalizedPrefix(canonicalPath, of: unavailablePath)
        }
        guard !overlapsUnavailablePath,
              SearchIndexBuilder.canEnumerateDirectory(canonicalPath) else {
            return .subtree(canonicalPath)
        }
        return .exact(canonicalPath)
    }

    private func noteIndexEvents(
        _ events: [FileSystemEvent],
        expectedSignature: SearchIndexSignature,
        watcherGeneration: Int
    ) async {
        guard watcherGeneration == self.watcherGeneration,
              expectedSignature == currentSignature else { return }
        await noteIndexEvents(events)
    }

    private func cancelPipeline() {
        stopWatching()
        contentEnrichmentTask?.cancel()
        contentEnrichmentTask = nil
        eventRefreshGeneration &+= 1
        eventRefreshTask?.cancel()
        eventRefreshTask = nil
        unresolvedRetryTask?.cancel()
        unresolvedRetryTask = nil
        watcherRetryTask?.cancel()
        watcherRetryTask = nil
        eventJournalFlushTask?.cancel()
        eventJournalFlushTask = nil
        eventJournalFlushGeneration += 1
        eventJournalIsDirty = false
        rebuildTask?.cancel()
        rebuildTask = nil
        rebuildGeneration += 1
        activeBuildGeneration = nil
        pendingSubtreeEventPaths.removeAll()
        pendingExactEventPaths.removeAll()
        pendingEventID = nil
        latestAppliedEventID = nil
        deferredEventCheckpointID = nil
        pendingEventsRequireFullRebuild = false
        pendingChangesRequireConservativeRefresh = false
        unresolvedSubtreeEventPaths.removeAll()
        unresolvedExactEventPaths.removeAll()
        knownUnavailablePaths.removeAll()
        unresolvedRetryAttempt = 0
        eventReplacements.removeAll()
        removeAllExactReplacements()
        revisionChangeBatches.removeAll()
        nextExactCompactionCount = 30_000
        clearInProgressBuild()
    }

    private func clearInProgressBuild() {
        inProgressSeen = []
        inProgressPathToIndex = [:]
        inProgressNodes = []
        acceptsPartialBuildBatches = true
        lastPartialPublish = nil
    }

    private func startRebuild(signature: SearchIndexSignature, tryCache: Bool) async -> SearchIndexStats {
        contentEnrichmentTask?.cancel()
        contentEnrichmentTask = nil
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
            let cachedState = await Task.detached(priority: .utility) {
                let cached = SearchIndexPersistence.load(signature: signature, from: persistenceURL)
                let delta = cached.flatMap { cached in
                    SearchIndexPersistence.loadDelta(
                        signature: signature,
                        baseLastEventID: cached.lastEventID,
                        from: persistenceURL
                    )
                }
                return (cached, delta)
            }.value
            guard rebuildGeneration == generation else { return currentStats }
            if let cached = cachedState.0 {
                // The durable snapshot was produced from a complete metadata
                // scan.  Treat it as query-ready immediately; the index event
                // callback below revokes this bit before applying any change,
                // and the replacement layer then restores freshness only when
                // its scan is complete.  This keeps a launch-time broad query
                // fast without narrowing the scope or discarding results.
                let initialValidationRoots = cached.unresolvedPaths
                    + (cachedState.1?.subtreePaths ?? [])
                    + (cachedState.1?.exactPaths ?? [])
                index = cached.withExistenceValidationRoots(
                    initialValidationRoots
                )
                knownUnavailablePaths = Set(cached.unresolvedPaths.map(SearchPath.canonicalAliasPath))
                eventReplacements.removeAll()
                removeAllExactReplacements()
                var stats = cached.stats
                stats.loadedFromDisk = true
                stats.processedEvents = currentStats.processedEvents
                stats.indexRevision = currentStats.indexRevision + 1
                currentStats = stats
                let delta = cachedState.1
                latestAppliedEventID = cached.lastEventID

                var restoredDeltaSubtreePaths = Set<String>()
                if let delta, !delta.subtreePaths.isEmpty || !delta.exactPaths.isEmpty {
                    // The metadata delta survives process restarts, while the
                    // content database may still describe the previous bytes.
                    // Revoke those rows before replaying the delta so a warm
                    // launch can never use a stale FTS miss to exclude a file.
                    await contentSearchIndex.invalidate(
                        exactPaths: delta.exactPaths,
                        subtreePaths: delta.subtreePaths
                    )
                    currentStats.isIndexing = true
                    let scanTask = Task.detached(priority: .utility) {
                        let exactReplacements = SearchIndexBuilder.scanExactReplacements(
                            paths: delta.exactPaths,
                            signature: signature,
                            pauseForForegroundSearch: true,
                            pathsAreCanonical: true,
                            pathsAreUnique: true
                        )
                        let subtreeReplacements = await SearchIndexBuilder.scanReplacements(
                            paths: delta.subtreePaths,
                            signature: signature
                        )
                        return (subtreeReplacements, exactReplacements)
                    }
                    let restored = await withTaskCancellationHandler {
                        await scanTask.value
                    } onCancel: {
                        scanTask.cancel()
                    }
                    guard rebuildGeneration == generation, !Task.isCancelled else { return currentStats }
                    restoredDeltaSubtreePaths.formUnion(restored.0.map(\.rootPath))
                    let compaction = await compactLargeSubtreeReplacements(
                        restored.0,
                        signature: signature,
                        expectedRebuildGeneration: generation,
                        forceAllComplete: true
                    )
                    guard rebuildGeneration == generation, !Task.isCancelled else { return currentStats }
                    let appliedSubtreeReplacements = installSubtreeReplacements(compaction.remaining)
                    let completedExactReplacements = restored.1.filter(\.isComplete)
                    for replacement in completedExactReplacements {
                        installExactReplacement(replacement)
                    }
                    resolveKnownUnavailablePaths(
                        subtreeReplacements: restored.0,
                        exactReplacements: completedExactReplacements
                    )
                    let unresolvedSubtreePaths = restored.0.flatMap(\.preservedBaseRoots)
                    let unresolvedExactPaths = restored.1.filter { !$0.isComplete }.map(\.path)
                    _ = await compactExactOverlayIfNeeded(
                        signature: signature,
                        expectedGeneration: generation
                    )
                    guard rebuildGeneration == generation, !Task.isCancelled else { return currentStats }
                    currentStats.isIndexing = false
                    currentStats.indexRevision += 1
                    if unresolvedSubtreePaths.isEmpty && unresolvedExactPaths.isEmpty {
                        latestAppliedEventID = delta.lastEventID
                        advanceEventJournal(to: nil, signature: signature)
                    } else {
                        queueUnresolvedEvents(
                            subtreePaths: unresolvedSubtreePaths,
                            exactPaths: unresolvedExactPaths,
                            eventID: delta.lastEventID
                        )
                    }
                    recordRevisionChanges(
                        revision: currentStats.indexRevision,
                        subtreeReplacements: compaction.incorporated + appliedSubtreeReplacements,
                        exactReplacements: completedExactReplacements,
                        requiresConservativeRefresh: true
                    )
                } else if let delta {
                    latestAppliedEventID = delta.lastEventID
                }
                let baselinePathsStillNeedingRetry = cached.unresolvedPaths.filter { path in
                    !restoredDeltaSubtreePaths.contains(where: {
                        SearchPath.hasNormalizedPrefix(path, of: $0)
                    })
                }
                if !baselinePathsStillNeedingRetry.isEmpty {
                    queueUnresolvedEvents(
                        subtreePaths: baselinePathsStillNeedingRetry,
                        exactPaths: [],
                        eventID: latestAppliedEventID
                    )
                }
                // Complete overlays make the unaffected base trustworthy.
                // Any partial holes remain visible but are validated only
                // within their recorded retry roots.
                restoreScopedIndexFreshnessIfPossible()
                index?.prewarmNameIndex()
                startWatching(signature: signature, sinceEventID: latestAppliedEventID)
                if let index { startBackgroundContentEnrichment(for: index) }
                return currentStats
            }
        }

        currentStats.isIndexing = true
        clearInProgressBuild()
        activeBuildGeneration = generation
        let keepsExistingIndexSearchableDuringBuild = index?.signature == signature
            && index?.hasCompleteMetadata == true
        let shouldBuildQueryReadyStage = queryReadyBuildOperation != nil
            && !keepsExistingIndexSearchableDuringBuild
        let baselineEventID = FileSystemEventWatcher.currentEventID()
        startWatching(
            signature: signature,
            sinceEventID: baselineEventID,
            ignoreEventsThrough: baselineEventID
        )
        if shouldBuildQueryReadyStage, let queryReadyBuildOperation {
            let queryReadyTask = Task.detached(priority: .utility) {
                await queryReadyBuildOperation(signature)
            }
            let queryReadyResult = await withTaskCancellationHandler {
                await queryReadyTask.value
            } onCancel: {
                queryReadyTask.cancel()
            }
            guard rebuildGeneration == generation, !Task.isCancelled else { return currentStats }

            let queryReadyIndex = SearchIndex(
                signature: signature,
                nodes: queryReadyResult.nodes,
                lastEventID: baselineEventID,
                unresolvedPaths: queryReadyResult.unresolvedPaths,
                pathsAreFresh: true,
                hasCompleteMetadata: false,
                deferNameIndexBuild: true
            )
            index = queryReadyIndex
            knownUnavailablePaths = Set(
                queryReadyResult.unresolvedPaths.map(SearchPath.canonicalAliasPath)
            )
            var queryReadyStats = queryReadyIndex.stats
            queryReadyStats.isIndexing = true
            queryReadyStats.isMetadataEnriching = true
            queryReadyStats.processedEvents = currentStats.processedEvents
            queryReadyStats.indexRevision = currentStats.indexRevision + 1
            currentStats = queryReadyStats
        }
        let buildOperation = buildOperation
        let onBatch: (@Sendable ([TempNode]) -> Void)?
        if queryReadyBuildOperation == nil && !keepsExistingIndexSearchableDuringBuild {
            onBatch = { batch in
                Task {
                    await self.appendBuildBatch(batch, signature: signature, generation: generation)
                }
            }
        } else {
            onBatch = nil
        }
        let buildTask = Task.detached(priority: .utility) { [signature, generation] in
            if let buildOperation {
                return await buildOperation(signature)
            }
            return await SearchIndexBuilder.buildWithDiagnostics(
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
                onBatch: onBatch
            )
        }
        let buildResult = await withTaskCancellationHandler {
            await buildTask.value
        } onCancel: {
            buildTask.cancel()
        }

        guard rebuildGeneration == generation else { return currentStats }
        activeBuildGeneration = nil

        var queryReadyFallback = index?.hasCompleteMetadata == false ? index : nil
        let enrichedNodes = SearchIndexBuilder.enrichedNodesPreservingQueryReadyCandidates(
            buildResult.nodes,
            queryReadyIndex: queryReadyFallback,
            unresolvedPaths: buildResult.unresolvedPaths,
            signature: signature
        )
        queryReadyFallback = nil
        // No suspension occurs between here and publishing `nextIndex`, so a
        // foreground snapshot cannot observe the brief nil. Releasing the old
        // complete/query-ready snapshot first avoids holding two multi-million
        // node name indexes while the replacement is assembled.
        index = nil
        ProcessMemoryReclaimer.releaseUnusedPages()
        let nextIndex = SearchIndex(
            signature: signature,
            nodes: enrichedNodes,
            lastEventID: baselineEventID,
            unresolvedPaths: buildResult.unresolvedPaths,
            pathsAreFresh: true,
            deferNameIndexBuild: true
        )
        knownUnavailablePaths = Set(buildResult.unresolvedPaths.map(SearchPath.canonicalAliasPath))
        var stats = nextIndex.stats
        stats.isIndexing = false
        stats.processedEvents = currentStats.processedEvents
        stats.indexRevision = currentStats.indexRevision + 1
        currentStats = stats

        index = nextIndex
        latestAppliedEventID = baselineEventID
        eventReplacements.removeAll()
        removeAllExactReplacements()
        clearInProgressBuild()
        persist(nextIndex)

        if buildResult.unresolvedPaths.isEmpty {
            unresolvedRetryTask?.cancel()
            unresolvedRetryTask = nil
            unresolvedSubtreeEventPaths.removeAll()
            unresolvedExactEventPaths.removeAll()
            knownUnavailablePaths.removeAll()
            updateUnavailablePathStats()
            unresolvedRetryAttempt = 0
            deferredEventCheckpointID = nil
        } else {
            queueUnresolvedEvents(
                subtreePaths: buildResult.unresolvedPaths,
                exactPaths: [],
                eventID: baselineEventID
            )
        }
        if watcher == nil {
            startWatching(
                signature: signature,
                sinceEventID: nextIndex.lastEventID,
                ignoreEventsThrough: baselineEventID
            )
        }
        if !pendingSubtreeEventPaths.isEmpty
            || !pendingExactEventPaths.isEmpty
            || pendingEventID != nil
            || pendingEventsRequireFullRebuild {
            scheduleEventRefresh()
        }
        startBackgroundContentEnrichment(for: nextIndex)
        ProcessMemoryReclaimer.schedule()
        return currentStats
    }

    private func startBackgroundContentEnrichment(for index: SearchIndex) {
        contentEnrichmentTask?.cancel()
        let options = Preferences.loadOptions()
        let configuredLimit = options.maxContentFileSize
        let backgroundCap: Int64 = 100 * 1_024 * 1_024
        let backgroundLimit = configuredLimit == 0
            ? backgroundCap
            : min(configuredLimit, backgroundCap)
        let contentSearchIndex = contentSearchIndex
        contentEnrichmentTask = Task.detached(priority: .background) {
            // Preserve cold-launch and first-query latency. Once started, every
            // document boundary also yields to active foreground searches.
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await BackgroundContentIndexEnricher.enrich(
                index: index,
                contentIndex: contentSearchIndex,
                maxFileSize: backgroundLimit,
                maximumDatabaseBytes: options.maxContentIndexBytes
            )
            ProcessMemoryReclaimer.schedule()
        }
    }

    /// Incrementally appends one scan batch to the in-progress index so
    /// searches during a build see already-scanned files. Append-only with a
    /// persistent path table (O(batch)); a node arriving before its parent
    /// stores its absolute path, which `path(for:)` returns verbatim, and the
    /// final full build replaces this partial index anyway. Publishing a
    /// snapshot is throttled because `SearchIndex.init` is O(n).
    private func appendBuildBatch(_ batch: [TempNode], signature: SearchIndexSignature, generation: Int) {
        guard activeBuildGeneration == generation,
              currentSignature == signature,
              acceptsPartialBuildBatches else { return }
        var reachedLimit = false
        for node in batch {
            if inProgressNodes.count >= maximumPartialBuildNodes {
                acceptsPartialBuildBatches = false
                reachedLimit = true
                break
            }
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
                creationTime: node.creationTime,
                isHiddenScope: node.isHiddenScope,
                isPackageDescendant: node.isPackageDescendant
            ))
        }

        let now = ContinuousClock.now
        if !reachedLimit,
           let last = lastPartialPublish,
           now - last < .milliseconds(300) { return }
        lastPartialPublish = now
        index = SearchIndex(signature: signature, nodes: inProgressNodes, buildNameIndex: false)
    }

    private func updateBuildProgress(signature: SearchIndexSignature, generation: Int, files: Int, directories: Int) {
        guard activeBuildGeneration == generation,
              currentSignature == signature,
              !currentStats.isMetadataEnriching else { return }
        currentStats.indexedFiles = files
        currentStats.indexedDirectories = directories
    }

    private func scheduleEventRefresh() {
        guard eventRefreshTask == nil, activeBuildGeneration == nil else { return }
        let signature = currentSignature
        eventRefreshGeneration &+= 1
        let generation = eventRefreshGeneration
        eventRefreshTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(700))
                } catch {
                    break
                }
                guard !Task.isCancelled else { break }
                await self.applyPendingEvents(
                    expectedSignature: signature,
                    eventRefreshGeneration: generation
                )
                guard await self.hasPendingEvents(
                    expectedSignature: signature,
                    eventRefreshGeneration: generation
                ) else { break }
            }
            await self.finishEventRefresh(
                expectedSignature: signature,
                eventRefreshGeneration: generation
            )
        }
    }

    private func hasPendingEvents(
        expectedSignature: SearchIndexSignature?,
        eventRefreshGeneration: Int
    ) -> Bool {
        eventRefreshGeneration == self.eventRefreshGeneration
            && expectedSignature == currentSignature
            && (!pendingSubtreeEventPaths.isEmpty
                || !pendingExactEventPaths.isEmpty
                || pendingEventID != nil
                || pendingEventsRequireFullRebuild)
    }

    private func finishEventRefresh(
        expectedSignature: SearchIndexSignature?,
        eventRefreshGeneration: Int
    ) {
        guard eventRefreshGeneration == self.eventRefreshGeneration else { return }
        eventRefreshTask = nil
        if hasPendingEvents(
            expectedSignature: expectedSignature,
            eventRefreshGeneration: eventRefreshGeneration
        ) {
            scheduleEventRefresh()
        }
    }

    private func applyPendingEvents(
        expectedSignature: SearchIndexSignature?,
        eventRefreshGeneration: Int
    ) async {
        guard eventRefreshGeneration == self.eventRefreshGeneration,
              expectedSignature == currentSignature,
              let signature = currentSignature,
              index != nil,
              activeBuildGeneration == nil else { return }

        let subtreePaths = Array(pendingSubtreeEventPaths)
        let exactPaths = Array(pendingExactEventPaths)
        let eventID = pendingEventID
        let requiresFullRebuild = pendingEventsRequireFullRebuild
        let requiresConservativeRefresh = pendingChangesRequireConservativeRefresh
        pendingSubtreeEventPaths.removeAll()
        pendingExactEventPaths.removeAll()
        pendingEventID = nil
        pendingEventsRequireFullRebuild = false
        pendingChangesRequireConservativeRefresh = false

        if requiresFullRebuild {
            currentStats.isIndexing = true
            _ = await startRebuild(signature: signature, tryCache: false)
            return
        }

        let refreshSubtreePaths = SearchIndexBuilder.collapseEventPaths(subtreePaths, signature: signature)
        let subtreeRoots = Set(refreshSubtreePaths)
        let ignoredPaths = SearchIndexBuilder.effectiveIgnoredPaths(for: signature)
        let refreshExactPaths = Array(Set(exactPaths.map(SearchPath.canonicalAliasPath)))
            .filter { path in
                signature.contains(path: path)
                    && !SearchIndexBuilder.isIgnored(path, ignoredPaths: ignoredPaths)
                    && !SearchIndexBuilder.isPath(path, coveredByRootPaths: subtreeRoots)
            }
            .sorted()

        guard !refreshSubtreePaths.isEmpty || !refreshExactPaths.isEmpty else {
            completeEventBatch(eventID: eventID, hasUnresolved: false, signature: signature)
            restoreScopedIndexFreshnessIfPossible()
            return
        }
        if refreshSubtreePaths.contains(where: signature.scopes.contains) {
            currentStats.isIndexing = true
            _ = await startRebuild(signature: signature, tryCache: false)
            return
        }

        currentStats.isIndexing = true
        // Incremental reconciliation must yield CPU and I/O to an interactive
        // query. Full index builds retain their wider worker pool; only this
        // background maintenance pass is deliberately lower priority.
        let scanTask = Task.detached(priority: .background) {
            let exactReplacements = SearchIndexBuilder.scanExactReplacements(
                paths: refreshExactPaths,
                signature: signature,
                pauseForForegroundSearch: true,
                pathsAreCanonical: true,
                pathsAreUnique: true
            )
            let subtreeReplacements = await SearchIndexBuilder.scanReplacements(
                paths: refreshSubtreePaths,
                signature: signature
            )
            return (subtreeReplacements, exactReplacements)
        }
        let scanned = await withTaskCancellationHandler {
            await scanTask.value
        } onCancel: {
            scanTask.cancel()
        }
        guard !Task.isCancelled,
              eventRefreshGeneration == self.eventRefreshGeneration,
              expectedSignature == currentSignature else { return }

        let compaction = await compactLargeSubtreeReplacements(
            scanned.0,
            signature: signature,
            expectedRebuildGeneration: rebuildGeneration,
            expectedEventRefreshGeneration: eventRefreshGeneration
        )
        guard !Task.isCancelled,
              eventRefreshGeneration == self.eventRefreshGeneration,
              expectedSignature == currentSignature else { return }

        let appliedSubtreeReplacements = installSubtreeReplacements(compaction.remaining)
        let completedExactReplacements = scanned.1.filter(\.isComplete)
        for replacement in completedExactReplacements {
            installExactReplacement(replacement)
        }
        resolveKnownUnavailablePaths(
            subtreeReplacements: scanned.0,
            exactReplacements: completedExactReplacements
        )
        let unresolvedSubtreePaths = scanned.0.flatMap(\.preservedBaseRoots)
        let unresolvedExactPaths = scanned.1.filter { !$0.isComplete }.map(\.path)
        queueUnresolvedEvents(
            subtreePaths: unresolvedSubtreePaths,
            exactPaths: unresolvedExactPaths,
            eventID: eventID
        )
        let compactedReplacements = await compactExactOverlayIfNeeded(
            signature: signature,
            expectedGeneration: rebuildGeneration
        )
        guard !Task.isCancelled,
              eventRefreshGeneration == self.eventRefreshGeneration,
              expectedSignature == currentSignature else { return }
        var stats = currentStats
        stats.isIndexing = false
        stats.indexRevision += 1
        currentStats = stats
        recordRevisionChanges(
            revision: stats.indexRevision,
            subtreeReplacements: compaction.incorporated + appliedSubtreeReplacements + compactedReplacements,
            exactReplacements: completedExactReplacements,
            requiresConservativeRefresh: requiresConservativeRefresh
        )
        completeEventBatch(
            eventID: eventID,
            hasUnresolved: !unresolvedSubtreePaths.isEmpty || !unresolvedExactPaths.isEmpty,
            signature: signature
        )
        restoreScopedIndexFreshnessIfPossible()
    }

    private func queueUnresolvedEvents(
        subtreePaths: [String],
        exactPaths: [String],
        eventID: UInt64?
    ) {
        let canonicalSubtreePaths = subtreePaths.map(SearchPath.canonicalAliasPath)
        let canonicalExactPaths = exactPaths.map(SearchPath.canonicalAliasPath)
        unresolvedSubtreeEventPaths.formUnion(canonicalSubtreePaths)
        unresolvedExactEventPaths.formUnion(canonicalExactPaths)
        knownUnavailablePaths.formUnion(canonicalSubtreePaths)
        knownUnavailablePaths.formUnion(canonicalExactPaths)
        updateUnavailablePathStats()
        if let eventID, eventID > 0 {
            deferredEventCheckpointID = max(deferredEventCheckpointID ?? 0, eventID)
        }
        guard !unresolvedSubtreeEventPaths.isEmpty || !unresolvedExactEventPaths.isEmpty else { return }
        // Persist retry roots as part of the delta instead of relying only on
        // the system history surviving until the next launch. The durable
        // base keeps its older event boundary, so this remains crash-safe even
        // while the retry is in flight.
        eventJournalIsDirty = true
        if let currentSignature {
            scheduleEventJournalFlush(signature: currentSignature)
        }
        scheduleUnresolvedRetry()
    }

    private func resolveKnownUnavailablePaths(
        subtreeReplacements: [SearchIndexReplacement],
        exactReplacements: [SearchIndexExactReplacement]
    ) {
        for replacement in subtreeReplacements {
            let preservedRoots = replacement.preservedBaseRoots.map(SearchPath.canonicalAliasPath)
            knownUnavailablePaths = knownUnavailablePaths.filter { unavailablePath in
                guard SearchPath.hasNormalizedPrefix(unavailablePath, of: replacement.rootPath) else {
                    return true
                }
                return preservedRoots.contains {
                    SearchPath.hasNormalizedPrefix(unavailablePath, of: $0)
                }
            }
        }
        for replacement in exactReplacements where replacement.isComplete {
            knownUnavailablePaths.remove(SearchPath.canonicalAliasPath(replacement.path))
        }
        updateUnavailablePathStats()
    }

    private func updateUnavailablePathStats() {
        currentStats.unavailablePaths = knownUnavailablePaths.count
    }

    private func scheduleUnresolvedRetry() {
        guard unresolvedRetryTask == nil else { return }
        let exponent = min(unresolvedRetryAttempt, 6)
        let delaySeconds = min(300, 5 * (1 << exponent))
        unresolvedRetryAttempt += 1
        unresolvedRetryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delaySeconds))
            } catch {
                return
            }
            await self?.promoteUnresolvedRetry()
        }
    }

    private func promoteUnresolvedRetry() {
        unresolvedRetryTask = nil
        guard currentSignature != nil else { return }
        pendingSubtreeEventPaths.formUnion(unresolvedSubtreeEventPaths)
        pendingExactEventPaths.formUnion(unresolvedExactEventPaths)
        unresolvedSubtreeEventPaths.removeAll()
        unresolvedExactEventPaths.removeAll()
        if let deferredEventCheckpointID {
            pendingEventID = max(pendingEventID ?? 0, deferredEventCheckpointID)
        }
        scheduleEventRefresh()
    }

    private func completeEventBatch(
        eventID: UInt64?,
        hasUnresolved: Bool,
        signature: SearchIndexSignature
    ) {
        if let eventID, eventID > 0 {
            deferredEventCheckpointID = max(deferredEventCheckpointID ?? 0, eventID)
        }
        guard !hasUnresolved,
              unresolvedSubtreeEventPaths.isEmpty,
              unresolvedExactEventPaths.isEmpty else { return }
        let checkpoint = deferredEventCheckpointID
        unresolvedRetryAttempt = 0
        deferredEventCheckpointID = nil
        advanceEventJournal(to: checkpoint, signature: signature)
    }

    @discardableResult
    private func installSubtreeReplacement(_ replacement: SearchIndexReplacement) -> Bool {
        let preservedRoots = Set(replacement.preservedBaseRoots)
        if preservedRoots.contains(replacement.rootPath) {
            return false
        }

        func shouldRemove(_ path: String) -> Bool {
            guard SearchPath.hasNormalizedPrefix(path, of: replacement.rootPath) else { return false }
            return path == replacement.rootPath
                || !SearchIndexBuilder.isPath(path, coveredByRootPaths: preservedRoots)
        }

        eventReplacements = eventReplacements.filter { !shouldRemove($0.key) }
        removeExactReplacements(where: shouldRemove)
        eventReplacements[replacement.rootPath] = replacement
        return true
    }

    /// Installs one reconciliation batch without repeatedly filtering the
    /// entire live overlay for every root. A large FSEvents burst can contain
    /// tens of thousands of disjoint subtree replacements; the former
    /// per-item implementation became quadratic and held the store actor long
    /// enough to block otherwise-ready searches.
    @discardableResult
    private func installSubtreeReplacements(
        _ replacements: [SearchIndexReplacement]
    ) -> [SearchIndexReplacement] {
        let valid = replacements.filter { replacement in
            !replacement.preservedBaseRoots.contains(replacement.rootPath)
        }
        guard !valid.isEmpty else { return [] }
        if valid.count == 1 {
            return installSubtreeReplacement(valid[0]) ? valid : []
        }

        let completeRoots = Set(valid.lazy
            .filter { $0.preservedBaseRoots.isEmpty }
            .map(\.rootPath))
        let completeRootIndex = SearchPathPrefixIndex(roots: Array(completeRoots))
        let partial = valid.compactMap {
            replacement -> (root: String, preserved: SearchPathPrefixIndex)? in
            guard !replacement.preservedBaseRoots.isEmpty else { return nil }
            return (
                replacement.rootPath,
                SearchPathPrefixIndex(roots: replacement.preservedBaseRoots)
            )
        }

        func shouldRemove(_ path: String) -> Bool {
            if completeRootIndex.contains(path) {
                return true
            }
            for replacement in partial {
                guard SearchPath.hasNormalizedPrefix(path, of: replacement.root) else { continue }
                if path == replacement.root
                    || !replacement.preserved.contains(path) {
                    return true
                }
            }
            return false
        }

        eventReplacements = eventReplacements.filter { !shouldRemove($0.key) }
        removeExactReplacements(where: shouldRemove)
        for replacement in valid {
            eventReplacements[replacement.rootPath] = replacement
        }
        return valid
    }

    /// Merge a complete, unusually large scan into the durable base. This is
    /// deliberately separate from `installSubtreeReplacement`: partial scans
    /// must remain overlays because their preserved holes still need the old
    /// snapshot, while a complete scan has no such fallback requirement.
    ///
    /// The returned `remaining` list is what the caller should install as an
    /// overlay. Existing overlays below an incorporated root are removed; an
    /// existing ancestor overlay blocks compaction because it would otherwise
    /// hide the newly merged base and make the result harder to reason about.
    private func compactLargeSubtreeReplacements(
        _ replacements: [SearchIndexReplacement],
        signature: SearchIndexSignature,
        expectedRebuildGeneration: Int,
        expectedEventRefreshGeneration: Int? = nil,
        forceAllComplete: Bool = false
    ) async -> (
        incorporated: [SearchIndexReplacement],
        remaining: [SearchIndexReplacement]
    ) {
        guard !replacements.isEmpty,
              let base = index,
              base.signature == signature,
              expectedRebuildGeneration == rebuildGeneration,
              expectedEventRefreshGeneration.map({ $0 == eventRefreshGeneration }) ?? true
        else {
            return ([], replacements)
        }

        let complete = replacements.filter {
            $0.preservedBaseRoots.isEmpty
                && (forceAllComplete || $0.nodes.count >= largeSubtreeCompactionThreshold)
                && signature.contains(path: $0.rootPath)
        }
        guard !complete.isEmpty else { return ([], replacements) }

        let collapsedRoots = Set(SearchIndexBuilder.collapseEventPaths(
            complete.map(\.rootPath),
            signature: signature
        ))
        guard !collapsedRoots.isEmpty else { return ([], replacements) }

        let ancestorRoots = eventReplacements.keys.map(SearchPath.canonicalAliasPath)
        let candidateRoots = collapsedRoots.filter { root in
            !ancestorRoots.contains { existing in
                existing != root && SearchPath.hasNormalizedPrefix(root, of: existing)
            }
        }
        guard !candidateRoots.isEmpty else { return ([], replacements) }

        let candidates = complete.filter {
            candidateRoots.contains(SearchPath.canonicalAliasPath($0.rootPath))
        }
        guard !candidates.isEmpty else { return ([], replacements) }

        let task = Task.detached(priority: .utility) {
            base.compacting(completeReplacements: candidates)
        }
        let compacted = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }

        guard !Task.isCancelled,
              expectedRebuildGeneration == rebuildGeneration,
              expectedEventRefreshGeneration.map({ $0 == eventRefreshGeneration }) ?? true,
              currentSignature == signature else {
            return ([], replacements)
        }

        let canonicalCandidateRoots = Set(candidateRoots.map(SearchPath.canonicalAliasPath))
        eventReplacements = eventReplacements.filter { key, _ in
            !SearchIndexBuilder.isPath(
                SearchPath.canonicalAliasPath(key),
                coveredByRootPaths: canonicalCandidateRoots
            )
        }
        removeExactReplacements { key in
            SearchIndexBuilder.isPath(
                SearchPath.canonicalAliasPath(key),
                coveredByRootPaths: canonicalCandidateRoots
            )
        }

        index = compacted
        var compactedStats = compacted.stats
        compactedStats.processedEvents = currentStats.processedEvents
        compactedStats.unavailablePaths = currentStats.unavailablePaths
        compactedStats.indexRevision = currentStats.indexRevision
        compactedStats.isIndexing = currentStats.isIndexing
        compactedStats.isMetadataEnriching = currentStats.isMetadataEnriching
        compactedStats.loadedFromDisk = currentStats.loadedFromDisk
        currentStats = compactedStats
        // Keep the old delta until this compacted base has landed, then let
        // the journal writer replace it with the smaller remaining overlay.
        // A crash between the two atomic writes can therefore cause redundant
        // replay, never a missing event range.
        persist(compacted, removeDelta: false)

        let remaining = replacements.filter { replacement in
            !SearchIndexBuilder.isPath(
                SearchPath.canonicalAliasPath(replacement.rootPath),
                coveredByRootPaths: canonicalCandidateRoots
            )
        }
        return (candidates, remaining)
    }

    private func compactExactOverlayIfNeeded(
        signature: SearchIndexSignature,
        expectedGeneration: Int
    ) async -> [SearchIndexReplacement] {
        let exactCount = eventExactReplacements.count
        guard exactCount >= nextExactCompactionCount else { return [] }
        let exactPaths = Array(eventExactReplacements.keys)
        let planningTask = Task.detached(priority: .background) {
            SearchIndexBuilder.exactOverlayCompactionRoots(
                paths: exactPaths,
                signature: signature,
                pathsAreCanonical: true,
                pathsAreUnique: true
            )
        }
        let roots = await withTaskCancellationHandler {
            await planningTask.value
        } onCancel: {
            planningTask.cancel()
        }
        guard !Task.isCancelled,
              expectedGeneration == rebuildGeneration,
              signature == currentSignature else { return [] }
        guard !roots.isEmpty else {
            nextExactCompactionCount = exactCount + 10_000
            return []
        }

        let task = Task.detached(priority: .utility) {
            await SearchIndexBuilder.scanReplacements(
                paths: roots,
                signature: signature,
                maximumNodesPerRoot: 20_000
            )
        }
        let replacements = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        guard !Task.isCancelled,
              expectedGeneration == rebuildGeneration,
              signature == currentSignature else { return [] }
        let installed = replacements.filter { installSubtreeReplacement($0) }
        nextExactCompactionCount = eventExactReplacements.count < 30_000
            ? 30_000
            : eventExactReplacements.count + 10_000
        return installed
    }

    private func recordRevisionChanges(
        revision: Int,
        subtreeReplacements: [SearchIndexReplacement],
        exactReplacements: [SearchIndexExactReplacement],
        requiresConservativeRefresh: Bool
    ) {
        let subtreeSummaries = subtreeReplacements.map {
            SearchIndexReplacement(rootPath: $0.rootPath, nodes: [])
        }
        revisionChangeBatches.append(RevisionChangeBatch(
            revision: revision,
            changes: SearchIndexChanges(
                subtreeReplacements: subtreeSummaries,
                exactReplacements: exactReplacements,
                requiresConservativeRefresh: requiresConservativeRefresh
            )
        ))
        if revisionChangeBatches.count > maxRevisionChangeBatches {
            revisionChangeBatches.removeFirst(revisionChangeBatches.count - maxRevisionChangeBatches)
        }
    }

    private func persist(_ index: SearchIndex, removeDelta: Bool = true) {
        eventJournalFlushTask?.cancel()
        eventJournalFlushTask = nil
        eventJournalFlushGeneration += 1
        eventJournalIsDirty = false
        let persistenceURL = persistenceURL
        let previousTask = persistTask
        persistTask = Task.detached(priority: .utility) {
            await previousTask?.value
            SearchIndexPersistence.save(
                index: index,
                to: persistenceURL,
                removeDelta: removeDelta
            )
        }
    }

    private func advanceEventJournal(to eventID: UInt64?, signature: SearchIndexSignature) {
        if let eventID, eventID > 0 {
            latestAppliedEventID = max(latestAppliedEventID ?? 0, eventID)
        }
        guard latestAppliedEventID != nil else { return }

        eventJournalIsDirty = true
        scheduleEventJournalFlush(signature: signature)
    }

    private func scheduleEventJournalFlush(signature: SearchIndexSignature) {
        guard eventJournalFlushTask == nil else { return }
        eventJournalFlushGeneration += 1
        let generation = eventJournalFlushGeneration
        eventJournalFlushTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }
            await self?.flushScheduledEventJournal(
                expectedSignature: signature,
                generation: generation
            )
        }
    }

    private func flushScheduledEventJournal(
        expectedSignature: SearchIndexSignature,
        generation: Int
    ) {
        guard generation == eventJournalFlushGeneration,
              expectedSignature == currentSignature else { return }
        eventJournalFlushTask = nil
        enqueueEventJournalPersistence(signature: expectedSignature)
    }

    private func enqueueEventJournalPersistence(signature: SearchIndexSignature) {
        guard eventJournalIsDirty,
              signature == currentSignature else { return }
        let journalLastEventID = max(
            latestAppliedEventID ?? 0,
            deferredEventCheckpointID ?? 0
        )
        guard journalLastEventID > 0 else { return }
        eventJournalIsDirty = false

        let persistenceURL = persistenceURL
        // Copy the actor-owned collections quickly, then do the expensive
        // deduplication and sorting in the detached persistence task. A busy
        // filesystem can keep tens of thousands of exact changes pending; doing
        // that work here would periodically queue searches behind the journal.
        let replacementSubtreePaths = Array(eventReplacements.keys)
        let unresolvedSubtreePaths = Array(unresolvedSubtreeEventPaths)
        let replacementExactPaths = Array(eventExactReplacements.keys)
        let unresolvedExactPaths = Array(unresolvedExactEventPaths)
        guard let baseLastEventID = index?.lastEventID, baseLastEventID > 0 else { return }
        let previousTask = persistTask
        persistTask = Task.detached(priority: .utility) {
            await previousTask?.value
            SearchIndexPersistence.saveCanonicalDelta(
                signature: signature,
                subtreePaths: replacementSubtreePaths + unresolvedSubtreePaths,
                exactPaths: replacementExactPaths + unresolvedExactPaths,
                baseLastEventID: baseLastEventID,
                lastEventID: journalLastEventID,
                to: persistenceURL
            )
        }
    }

    func flushPersistence() async {
        eventJournalFlushTask?.cancel()
        eventJournalFlushTask = nil
        eventJournalFlushGeneration += 1
        if let currentSignature {
            enqueueEventJournalPersistence(signature: currentSignature)
        }
        let task = persistTask
        await task?.value
        await contentSearchIndex.flush()
    }

    @discardableResult
    static func eventsAfterFreshBuildBaseline(
        _ events: [FileSystemEvent],
        ignoringThrough baselineEventID: UInt64?
    ) -> [FileSystemEvent] {
        guard let baselineEventID else { return events }
        return events.filter { $0.eventID == 0 || $0.eventID > baselineEventID }
    }

    @discardableResult
    private func startWatching(
        signature: SearchIndexSignature,
        sinceEventID: UInt64?,
        ignoreEventsThrough baselineEventID: UInt64? = nil
    ) -> Bool {
        stopWatching()
        let generation = watcherGeneration
        watcher = FileSystemEventWatcher(
            paths: signature.scopes,
            sinceEventID: sinceEventID,
            fileEvents: true
        ) { [weak self] events in
            await self?.noteIndexEvents(
                Self.eventsAfterFreshBuildBaseline(
                    events,
                    ignoringThrough: baselineEventID
                ),
                expectedSignature: signature,
                watcherGeneration: generation
            )
        }
        eventLogWatcher = FileSystemEventWatcher(
            paths: signature.scopes,
            fileEvents: true
        ) { [weak self] events in
            await self?.noteFileEvents(
                events,
                expectedSignature: signature,
                watcherGeneration: generation
            )
        }
        if watcher == nil {
            scheduleWatcherRetry(
                signature: signature,
                sinceEventID: sinceEventID,
                ignoreEventsThrough: baselineEventID
            )
            return false
        }
        watcherRetryTask?.cancel()
        watcherRetryTask = nil
        return true
    }

    private func scheduleWatcherRetry(
        signature: SearchIndexSignature,
        sinceEventID: UInt64?,
        ignoreEventsThrough baselineEventID: UInt64?
    ) {
        guard watcherRetryTask == nil else { return }
        watcherRetryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }
            await self?.retryWatcher(
                signature: signature,
                sinceEventID: sinceEventID,
                ignoreEventsThrough: baselineEventID
            )
        }
    }

    private func retryWatcher(
        signature: SearchIndexSignature,
        sinceEventID: UInt64?,
        ignoreEventsThrough baselineEventID: UInt64?
    ) {
        watcherRetryTask = nil
        guard signature == currentSignature else { return }
        startWatching(
            signature: signature,
            sinceEventID: latestAppliedEventID ?? sinceEventID,
            ignoreEventsThrough: baselineEventID
        )
    }

    private func stopWatching() {
        watcherGeneration &+= 1
        watcher?.stop()
        watcher = nil
        eventLogWatcher?.stop()
        eventLogWatcher = nil
    }
}

struct TempNode: Sendable {
    let path: String
    let isDirectory: Bool
    let size: Int64
    let modifiedTime: Double
    let creationTime: Double
    let isHiddenScope: Bool
    let isPackageDescendant: Bool

    /// The filename is fully determined by the absolute path. Keeping a
    /// second String per node adds substantial peak memory during a whole-Mac
    /// build without preserving any extra information.
    var name: String {
        path == "/" ? "/" : (path as NSString).lastPathComponent
    }

    init(
        path: String,
        name _: String,
        isDirectory: Bool,
        size: Int64,
        modifiedTime: Double,
        creationTime: Double,
        isHiddenScope: Bool,
        isPackageDescendant: Bool
    ) {
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.modifiedTime = modifiedTime
        self.creationTime = creationTime
        self.isHiddenScope = isHiddenScope
        self.isPackageDescendant = isPackageDescendant
    }

    var resolvedNode: ResolvedNode {
        ResolvedNode(
            node: IndexedFileNode(
                name: path,
                parentIndex: -1,
                isDirectory: isDirectory,
                size: size,
                modifiedTime: modifiedTime,
                creationTime: creationTime,
                isHiddenScope: isHiddenScope,
                isPackageDescendant: isPackageDescendant
            ),
            path: path
        )
    }
}

/// Work-stealing queue for directory scanning. Workers pull one directory at a
/// time and push its subdirectories back, so a single huge subtree spreads
/// across all workers instead of becoming one task's long tail.
final class DirectoryIdentityChain: @unchecked Sendable {
    let identity: BulkDirectoryIdentity
    let parent: DirectoryIdentityChain?

    init(identity: BulkDirectoryIdentity, parent: DirectoryIdentityChain?) {
        self.identity = identity
        self.parent = parent
    }

    func contains(_ candidate: BulkDirectoryIdentity) -> Bool {
        var current: DirectoryIdentityChain? = self
        while let node = current {
            if node.identity == candidate { return true }
            current = node.parent
        }
        return false
    }
}

struct ScanDirectory: Sendable {
    let path: String
    /// Applies to every immediate child of `path`.
    let descendantsAreHidden: Bool
    /// Applies to every immediate child of `path`.
    let descendantsArePackage: Bool
    /// Physical identities already traversed on this path. This is ancestry,
    /// not a global visited set: two user-visible aliases remain searchable,
    /// while an alias back to an ancestor cannot recurse forever.
    let ancestorIdentities: DirectoryIdentityChain?
}

struct QueryReadyScanDirectory: Sendable {
    let path: String
    let nodeIndex: Int32
    let descendantsAreHidden: Bool
    let descendantsArePackage: Bool
    let ancestorIdentities: DirectoryIdentityChain?
}

/// Appends compact parent-linked nodes while directories are discovered. A
/// child directory is queued only after its parent batch receives stable node
/// indices, eliminating the full path-to-index assembly pass from stage one.
final class QueryReadyNodeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var nodes: [IndexedFileNode] = []

    func append(_ batch: [IndexedFileNode]) -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        guard nodes.count <= Int(Int32.max) - batch.count else { return nil }
        let start = Int32(nodes.count)
        nodes.append(contentsOf: batch)
        return start
    }

    func snapshot() -> [IndexedFileNode] {
        lock.lock()
        defer { lock.unlock() }
        return nodes
    }
}

final class QueryReadyScanCoordinator: @unchecked Sendable {
    enum Slot {
        case directory(QueryReadyScanDirectory)
        case wait
        case done
    }

    private let lock = NSLock()
    private var pending: [QueryReadyScanDirectory]
    private var inFlight = 0

    init(roots: [QueryReadyScanDirectory]) {
        pending = roots
    }

    func next() -> Slot {
        lock.lock()
        defer { lock.unlock() }
        if let directory = pending.popLast() {
            inFlight += 1
            return .directory(directory)
        }
        return inFlight == 0 ? .done : .wait
    }

    func complete(subdirectories: [QueryReadyScanDirectory]) {
        lock.lock()
        pending.append(contentsOf: subdirectories)
        inFlight -= 1
        lock.unlock()
    }
}

final class ScanCoordinator: @unchecked Sendable {
    enum Slot {
        case directory(ScanDirectory)
        case wait
        case done
    }

    private let lock = NSLock()
    private var pending: [ScanDirectory]
    private var inFlight = 0

    init(roots: [ScanDirectory]) {
        pending = roots
    }

    func next() -> Slot {
        lock.lock()
        defer { lock.unlock() }
        if let directory = pending.popLast() {
            inFlight += 1
            return .directory(directory)
        }
        return inFlight == 0 ? .done : .wait
    }

    func complete(subdirectories: [ScanDirectory]) {
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

/// Bounds the memory used by the temporary, searchable snapshot published
/// while a full build is still running. The completed build always retains
/// every scanned node; only the transient preview is capped.
final class PartialBuildPublisher: @unchecked Sendable {
    private let lock = NSLock()
    private var remainingNodes: Int
    private let publishBatch: @Sendable ([TempNode]) -> Void

    init(maximumNodes: Int?, publishBatch: @escaping @Sendable ([TempNode]) -> Void) {
        remainingNodes = maximumNodes.map { max(0, $0) } ?? .max
        self.publishBatch = publishBatch
    }

    func publish(_ batch: [TempNode]) {
        lock.lock()
        let count = min(remainingNodes, batch.count)
        remainingNodes -= count
        lock.unlock()

        guard count > 0 else { return }
        if count == batch.count {
            publishBatch(batch)
        } else {
            publishBatch(Array(batch.prefix(count)))
        }
    }
}

struct SearchIndexBuildResult: Sendable {
    let nodes: [IndexedFileNode]
    let unresolvedPaths: [String]
}

enum SearchIndexBuilder {
    private static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey,
        .isSymbolicLinkKey,
        .fileSizeKey,
        .contentModificationDateKey,
        .creationDateKey,
        .isHiddenKey,
        .isPackageKey,
    ]

    private static let packageExtensions: Set<String> = [
        "app", "bundle", "framework", "plugin", "appex", "xpc", "kext", "pkg",
        "pages", "numbers", "key", "rtfd",
    ]

    static func build(
        signature: SearchIndexSignature,
        progress: @escaping @Sendable (_ files: Int, _ directories: Int) -> Void = { _, _ in },
        onBatch: (@Sendable ([TempNode]) -> Void)? = nil,
        maximumPartialNodes: Int? = 250_000
    ) async -> [IndexedFileNode] {
        await buildWithDiagnostics(
            signature: signature,
            progress: progress,
            onBatch: onBatch,
            maximumPartialNodes: maximumPartialNodes
        ).nodes
    }

    /// Builds the complete searchable topology without fetching file size or
    /// timestamps. Nodes are parent-linked as directory batches arrive, so the
    /// first stage avoids both the metadata payload and the later O(n) path
    /// dictionary used by the durable enriched index.
    static func buildQueryReadyWithDiagnostics(
        signature: SearchIndexSignature,
        progress: @escaping @Sendable (_ files: Int, _ directories: Int) -> Void = { _, _ in }
    ) async -> SearchIndexBuildResult {
        let ignoredPaths = effectiveIgnoredPaths(for: signature)
        let tracker = ProgressTracker(progress: progress)
        let collector = QueryReadyNodeCollector()
        var roots: [QueryReadyScanDirectory] = []
        var initialUnresolvedPaths: [String] = []
        var rootFiles = 0
        var rootDirectories = 0

        for scope in signature.scopes {
            guard let fullRoot = makeTempNode(url: URL(fileURLWithPath: scope)) else {
                if pathState(scope) != .missing { initialUnresolvedPaths.append(scope) }
                continue
            }
            let rootNode = IndexedFileNode(
                name: fullRoot.path,
                parentIndex: -1,
                isDirectory: fullRoot.isDirectory,
                size: 0,
                modifiedTime: 0,
                creationTime: 0,
                isHiddenScope: fullRoot.isHiddenScope,
                isPackageDescendant: fullRoot.isPackageDescendant
            )
            guard let rootIndex = collector.append([rootNode]) else {
                initialUnresolvedPaths.append(scope)
                continue
            }
            if fullRoot.isDirectory {
                rootDirectories += 1
                roots.append(QueryReadyScanDirectory(
                    path: fullRoot.path,
                    nodeIndex: rootIndex,
                    descendantsAreHidden: fullRoot.isHiddenScope,
                    descendantsArePackage: fullRoot.isPackageDescendant
                        || isPackageComponent(fullRoot.name),
                    ancestorIdentities: nil
                ))
            } else {
                rootFiles += 1
            }
        }
        if rootFiles > 0 || rootDirectories > 0 {
            tracker.record(files: rootFiles, directories: rootDirectories)
        }

        let workerCount = min(9, max(4, ProcessInfo.processInfo.activeProcessorCount))
        let coordinator = QueryReadyScanCoordinator(roots: roots)
        let workerUnresolved = await withTaskGroup(of: [String].self) { group in
            for _ in 0..<workerCount {
                group.addTask {
                    var unresolvedPaths: [String] = []
                    var localFiles = 0
                    var localDirectories = 0
                    var processedDirectories = 0

                    while !Task.isCancelled {
                        let slot = coordinator.next()
                        if case .done = slot { break }
                        guard case .directory(let directory) = slot else {
                            try? await Task.sleep(for: .milliseconds(2))
                            continue
                        }

                        processedDirectories += 1
                        if processedDirectories.isMultiple(of: 16) { await Task.yield() }

                        var currentDirectoryIdentity: BulkDirectoryIdentity?
                        let bulkEntries: [BulkDirectoryTopologyEntry]?
                        do {
                            bulkEntries = try BulkDirectoryReader.readTopology(
                                path: directory.path,
                                claimIdentity: { identity in
                                    currentDirectoryIdentity = identity
                                    return directory.ancestorIdentities?.contains(identity) != true
                                }
                            )
                        } catch {
                            if shouldRetryScanFailure(error, path: directory.path) {
                                unresolvedPaths.append(directory.path)
                            }
                            coordinator.complete(subdirectories: [])
                            continue
                        }

                        let childAncestorIdentities = currentDirectoryIdentity.map {
                            DirectoryIdentityChain(
                                identity: $0,
                                parent: directory.ancestorIdentities
                            )
                        }
                        var entries: [(name: String, isDirectory: Bool, isHidden: Bool)] = []
                        if let bulkEntries {
                            entries.reserveCapacity(bulkEntries.count)
                            for entry in bulkEntries {
                                entries.append((entry.name, entry.isDirectory, entry.isHidden))
                            }
                        } else {
                            let children: [URL]
                            do {
                                children = try FileManager.default.contentsOfDirectory(
                                    at: URL(fileURLWithPath: directory.path),
                                    includingPropertiesForKeys: [
                                        .isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey,
                                    ],
                                    options: []
                                )
                            } catch {
                                if shouldRetryScanFailure(error, path: directory.path) {
                                    unresolvedPaths.append(directory.path)
                                }
                                coordinator.complete(subdirectories: [])
                                continue
                            }
                            entries.reserveCapacity(children.count)
                            for child in children {
                                do {
                                    let values = try child.resourceValues(forKeys: [
                                        .isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey,
                                    ])
                                    let name = child.lastPathComponent
                                    entries.append((
                                        name,
                                        values.isDirectory == true && values.isSymbolicLink != true,
                                        values.isHidden == true || name.hasPrefix(".")
                                    ))
                                } catch {
                                    let path = SearchPath.canonicalAliasPath(
                                        child.path(percentEncoded: false)
                                    )
                                    if shouldRetryScanFailure(error, path: path) {
                                        unresolvedPaths.append(path)
                                    }
                                }
                            }
                        }

                        var batch: [IndexedFileNode] = []
                        var pendingDirectories: [(
                            offset: Int,
                            path: String,
                            descendantsAreHidden: Bool,
                            descendantsArePackage: Bool
                        )] = []
                        batch.reserveCapacity(entries.count)
                        pendingDirectories.reserveCapacity(entries.count / 8)
                        for entry in entries {
                            let childPath = SearchPath.appendingCanonicalComponent(
                                entry.name,
                                to: directory.path
                            )
                            guard signature.containsCanonicalPath(childPath),
                                  !isIgnored(childPath, ignoredPaths: ignoredPaths) else {
                                continue
                            }
                            let isHidden = directory.descendantsAreHidden || entry.isHidden
                            let isPackageDescendant = directory.descendantsArePackage
                            let offset = batch.count
                            batch.append(IndexedFileNode(
                                name: entry.name,
                                parentIndex: directory.nodeIndex,
                                isDirectory: entry.isDirectory,
                                size: 0,
                                modifiedTime: 0,
                                creationTime: 0,
                                isHiddenScope: isHidden,
                                isPackageDescendant: isPackageDescendant
                            ))
                            if entry.isDirectory {
                                localDirectories += 1
                                pendingDirectories.append((
                                    offset,
                                    childPath,
                                    isHidden,
                                    isPackageDescendant || isPackageComponent(entry.name)
                                ))
                            } else {
                                localFiles += 1
                            }
                        }

                        guard let batchStart = collector.append(batch) else {
                            unresolvedPaths.append(directory.path)
                            coordinator.complete(subdirectories: [])
                            continue
                        }
                        let subdirectories = pendingDirectories.map { pending in
                            QueryReadyScanDirectory(
                                path: pending.path,
                                nodeIndex: batchStart + Int32(pending.offset),
                                descendantsAreHidden: pending.descendantsAreHidden,
                                descendantsArePackage: pending.descendantsArePackage,
                                ancestorIdentities: childAncestorIdentities
                            )
                        }
                        coordinator.complete(subdirectories: subdirectories)

                        if localFiles + localDirectories >= 500 {
                            tracker.record(files: localFiles, directories: localDirectories)
                            localFiles = 0
                            localDirectories = 0
                        }
                    }

                    if localFiles > 0 || localDirectories > 0 {
                        tracker.record(files: localFiles, directories: localDirectories)
                    }
                    return unresolvedPaths
                }
            }

            var unresolved = initialUnresolvedPaths
            for await paths in group {
                unresolved.append(contentsOf: paths)
            }
            return unresolved
        }

        var nodes = collector.snapshot()
        var unresolvedPaths = collapseEventPaths(workerUnresolved, signature: signature)
        if !unresolvedPaths.isEmpty {
            var tempNodes = SearchIndex(
                signature: signature,
                nodes: nodes,
                buildNameIndex: false,
                basePathsAreCanonicalUnique: true
            ).toTempNodes()
            for attempt in 0..<2 where !unresolvedPaths.isEmpty && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100 * (attempt + 1)))
                let retries = await scanReplacements(paths: unresolvedPaths, signature: signature)
                tempNodes.append(contentsOf: retries.flatMap(\.nodes).map { queryReadyTempNode($0) })
                unresolvedPaths = collapseEventPaths(
                    retries.flatMap(\.preservedBaseRoots),
                    signature: signature
                )
            }
            deduplicateTempNodesInPlace(&tempNodes)
            nodes = assembleIndexedNodes(from: tempNodes)
        }

        let files = nodes.reduce(into: 0) { count, node in
            if !node.isDirectory { count += 1 }
        }
        progress(files, nodes.count - files)
        return SearchIndexBuildResult(nodes: nodes, unresolvedPaths: unresolvedPaths)
    }

    static func buildWithDiagnostics(
        signature: SearchIndexSignature,
        progress: @escaping @Sendable (_ files: Int, _ directories: Int) -> Void = { _, _ in },
        onBatch: (@Sendable ([TempNode]) -> Void)? = nil,
        maximumPartialNodes: Int? = 250_000
    ) async -> SearchIndexBuildResult {
        let ignoredPaths = effectiveIgnoredPaths(for: signature)
        let tracker = ProgressTracker(progress: progress)
        let partialPublisher = onBatch.map {
            PartialBuildPublisher(maximumNodes: maximumPartialNodes, publishBatch: $0)
        }

        var directNodes: [TempNode] = []
        var rootDirectories: [ScanDirectory] = []
        var initialUnresolvedPaths: [String] = []
        for scope in signature.scopes {
            guard let scopeNode = makeTempNode(url: URL(fileURLWithPath: scope)) else {
                if pathState(scope) != .missing { initialUnresolvedPaths.append(scope) }
                continue
            }
            directNodes.append(scopeNode)
            if scopeNode.isDirectory {
                rootDirectories.append(ScanDirectory(
                    path: scopeNode.path,
                    descendantsAreHidden: scopeNode.isHiddenScope,
                    descendantsArePackage: scopeNode.isPackageDescendant
                        || isPackageComponent(scopeNode.name),
                    ancestorIdentities: nil
                ))
            }
        }
        partialPublisher?.publish(directNodes)

        // `getattrlistbulk` spends most of its time waiting in APFS. Use the
        // available cores (with a conservative cap) so one slow subtree does
        // not leave performance cores idle during a whole-Mac rebuild.
        let workerCount = min(9, max(4, ProcessInfo.processInfo.activeProcessorCount))
        let coordinator = ScanCoordinator(roots: rootDirectories)

        var scanOutput = await withTaskGroup(of: ([TempNode], [String]).self) { group in
            for _ in 0..<workerCount {
                group.addTask {
                    var collected: [TempNode] = []
                    var pendingBatch: [TempNode] = []
                    var localFiles = 0
                    var localDirs = 0
                    var processedDirs = 0
                    var unresolvedPaths: [String] = []

                    while !Task.isCancelled {
                        let slot = coordinator.next()
                        if case .done = slot { break }
                        guard case .directory(let directory) = slot else {
                            // Queue momentarily empty while other workers still
                            // expand directories; back off briefly and retry.
                            try? await Task.sleep(for: .milliseconds(2))
                            continue
                        }

                        processedDirs += 1
                        if processedDirs % 16 == 0 {
                            await Task.yield()
                        }

                        var subdirectories: [ScanDirectory] = []
                        let bulkEntries: [BulkDirectoryEntry]?
                        var currentDirectoryIdentity: BulkDirectoryIdentity?
                        do {
                            bulkEntries = try BulkDirectoryReader.read(
                                path: directory.path,
                                claimIdentity: { identity in
                                    currentDirectoryIdentity = identity
                                    return directory.ancestorIdentities?.contains(identity) != true
                                }
                            )
                        } catch {
                            if shouldRetryScanFailure(error, path: directory.path) {
                                unresolvedPaths.append(directory.path)
                            }
                            coordinator.complete(subdirectories: [])
                            continue
                        }

                        let childAncestorIdentities = currentDirectoryIdentity.map {
                            DirectoryIdentityChain(
                                identity: $0,
                                parent: directory.ancestorIdentities
                            )
                        }

                        if let bulkEntries {
                            for entry in bulkEntries {
                                let childPath = SearchPath.appendingCanonicalComponent(
                                    entry.name,
                                    to: directory.path
                                )
                                guard signature.containsCanonicalPath(childPath) else { continue }
                                if isIgnored(childPath, ignoredPaths: ignoredPaths) { continue }
                                let node = TempNode(
                                    path: childPath,
                                    name: entry.name,
                                    isDirectory: entry.isDirectory,
                                    size: entry.size,
                                    modifiedTime: entry.modifiedTime,
                                    creationTime: entry.creationTime,
                                    isHiddenScope: directory.descendantsAreHidden || entry.isHidden,
                                    isPackageDescendant: directory.descendantsArePackage
                                )
                                recordScannedNode(
                                    node,
                                    componentName: entry.name,
                                    collected: &collected,
                                    pendingBatch: &pendingBatch,
                                    subdirectories: &subdirectories,
                                    localFiles: &localFiles,
                                    localDirectories: &localDirs,
                                    publishesPartialResults: partialPublisher != nil,
                                    ancestorIdentities: childAncestorIdentities
                                )
                                if localFiles + localDirs >= 500 {
                                    tracker.record(files: localFiles, directories: localDirs)
                                    localFiles = 0
                                    localDirs = 0
                                }
                            }
                        } else {
                            let children: [URL]
                            do {
                                children = try FileManager.default.contentsOfDirectory(
                                    at: URL(fileURLWithPath: directory.path),
                                    includingPropertiesForKeys: resourceKeys,
                                    options: []
                                )
                            } catch {
                                if shouldRetryScanFailure(error, path: directory.path) {
                                    unresolvedPaths.append(directory.path)
                                }
                                coordinator.complete(subdirectories: [])
                                continue
                            }

                            for child in children {
                                let childPath = SearchPath.normalize(child.path(percentEncoded: false))
                                guard signature.contains(path: childPath) else { continue }
                                if isIgnored(childPath, ignoredPaths: ignoredPaths) { continue }
                                guard let node = makeTempNode(url: child) else {
                                    if pathState(childPath) != .missing {
                                        unresolvedPaths.append(childPath)
                                    }
                                    continue
                                }
                                recordScannedNode(
                                    node,
                                    componentName: child.lastPathComponent,
                                    collected: &collected,
                                    pendingBatch: &pendingBatch,
                                    subdirectories: &subdirectories,
                                    localFiles: &localFiles,
                                    localDirectories: &localDirs,
                                    publishesPartialResults: partialPublisher != nil,
                                    ancestorIdentities: childAncestorIdentities
                                )
                                if localFiles + localDirs >= 500 {
                                    tracker.record(files: localFiles, directories: localDirs)
                                    localFiles = 0
                                    localDirs = 0
                                }
                            }
                        }

                        coordinator.complete(subdirectories: subdirectories)

                        if pendingBatch.count >= 2048 {
                            partialPublisher?.publish(pendingBatch)
                            pendingBatch.removeAll(keepingCapacity: true)
                        }
                    }

                    if localFiles > 0 || localDirs > 0 {
                        tracker.record(files: localFiles, directories: localDirs)
                    }
                    if !pendingBatch.isEmpty {
                        partialPublisher?.publish(pendingBatch)
                    }
                    return (collected, unresolvedPaths)
                }
            }

            var combined = directNodes
            var unresolved = initialUnresolvedPaths
            for await (taskNodes, taskUnresolvedPaths) in group {
                combined.append(contentsOf: taskNodes)
                unresolved.append(contentsOf: taskUnresolvedPaths)
            }
            return (combined, unresolved)
        }

        var unresolvedPaths = collapseEventPaths(scanOutput.1, signature: signature)
        let appendedRetryNodes = !unresolvedPaths.isEmpty
        for attempt in 0..<2 where !unresolvedPaths.isEmpty && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100 * (attempt + 1)))
            let retries = await scanReplacements(paths: unresolvedPaths, signature: signature)
            scanOutput.0.append(contentsOf: retries.flatMap(\.nodes))
            unresolvedPaths = collapseEventPaths(
                retries.flatMap(\.preservedBaseRoots),
                signature: signature
            )
        }

        // Collapsed scopes plus a no-follow directory work queue produce each
        // path once. Only retry scans can append a node already seen by the
        // first pass, so avoid a multi-million-entry Set on the normal path.
        if appendedRetryNodes {
            deduplicateTempNodesInPlace(&scanOutput.0)
        }
        let uniqueTempNodes = scanOutput.0

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

        return SearchIndexBuildResult(
            nodes: assembleIndexedNodes(from: uniqueTempNodes),
            unresolvedPaths: unresolvedPaths
        )
    }

    static func scanReplacements(
        paths: [String],
        signature: SearchIndexSignature,
        maximumNodesPerRoot: Int? = nil
    ) async -> [SearchIndexReplacement] {
        let ignoredPaths = effectiveIgnoredPaths(for: signature)
        var remainingPaths = Set(paths
            .map { SearchPath.canonicalAliasPath(SearchPath.normalize($0)) }
            .filter { signature.contains(path: $0) && !isIgnored($0, ignoredPaths: ignoredPaths) })
        guard !remainingPaths.isEmpty else { return [] }
        var replacements: [SearchIndexReplacement] = []

        while !remainingPaths.isEmpty, !Task.isCancelled {
            let frontier = collapseEventPaths(Array(remainingPaths), signature: signature)
            guard !frontier.isEmpty else { break }
            let scanned = await scanReplacementBatch(
                paths: frontier,
                signature: signature,
                ignoredPaths: ignoredPaths,
                maximumNodesPerRoot: maximumNodesPerRoot
            )
            replacements.append(contentsOf: scanned)
            remainingPaths.subtract(frontier)

            // A complete parent replacement already contains every nested
            // journal root. Only retain a nested path when the nearest scanned
            // ancestor reported a real enumeration hole that overlaps it.
            remainingPaths = Set(remainingPaths.filter { path in
                let coveringReplacement = replacements
                    .filter { SearchPath.hasNormalizedPrefix(path, of: $0.rootPath) }
                    .max { $0.rootPath.utf8.count < $1.rootPath.utf8.count }
                guard let coveringReplacement else { return true }
                return coveringReplacement.preservedBaseRoots.contains { preservedRoot in
                    SearchPath.hasNormalizedPrefix(path, of: preservedRoot)
                        || SearchPath.hasNormalizedPrefix(preservedRoot, of: path)
                }
            })
        }

        return replacements.sorted { $0.rootPath < $1.rootPath }
    }

    private static func scanReplacementBatch(
        paths: [String],
        signature: SearchIndexSignature,
        ignoredPaths: [String],
        maximumNodesPerRoot: Int?
    ) async -> [SearchIndexReplacement] {
        guard !paths.isEmpty else { return [] }
        // Each broad root may already enumerate a very large subtree. Process
        // event/delta roots one at a time so nested concurrency cannot reclaim
        // multiple cores behind an otherwise responsive foreground UI.
        let maxConcurrency = min(1, paths.count)

        return await withTaskGroup(of: SearchIndexReplacement.self) { group in
            var nextIndex = 0
            for _ in 0..<maxConcurrency {
                let path = paths[nextIndex]
                nextIndex += 1
                group.addTask {
                    await scanReplacement(
                        path: path,
                        signature: signature,
                        ignoredPaths: ignoredPaths,
                        maximumNodes: maximumNodesPerRoot
                    )
                }
            }

            var replacements: [SearchIndexReplacement] = []
            replacements.reserveCapacity(paths.count)
            while let replacement = await group.next() {
                replacements.append(replacement)
                if nextIndex < paths.count {
                    let path = paths[nextIndex]
                    nextIndex += 1
                    group.addTask {
                        await scanReplacement(
                            path: path,
                            signature: signature,
                            ignoredPaths: ignoredPaths,
                            maximumNodes: maximumNodesPerRoot
                        )
                    }
                }
            }
            return replacements
        }
    }

    static func scanExactReplacements(
        paths: [String],
        signature: SearchIndexSignature,
        pauseForForegroundSearch: Bool = false,
        pathsAreCanonical: Bool = false,
        pathsAreUnique: Bool = false
    ) -> [SearchIndexExactReplacement] {
        let ignoredPaths = effectiveIgnoredPaths(for: signature)
        let normalizedPaths = (pathsAreCanonical
            ? paths
            : paths.map(SearchPath.canonicalAliasPath))
            .map { String(decoding: $0.utf8, as: UTF8.self) }
        let uniquePaths = pathsAreUnique ? normalizedPaths : Array(Set(normalizedPaths))
        let canonicalPaths = uniquePaths
            .filter {
                signature.containsCanonicalPath($0)
                    && !isIgnored($0, ignoredPaths: ignoredPaths)
            }
            .sorted()

        var replacements: [SearchIndexExactReplacement] = []
        replacements.reserveCapacity(canonicalPaths.count)
        for (index, path) in canonicalPaths.enumerated() {
            guard !Task.isCancelled else { break }
            if pauseForForegroundSearch, index.isMultiple(of: 128) {
                SearchWorkCoordinator.shared.waitForSearchesToFinish()
                guard !Task.isCancelled else { break }
            }
            replacements.append(scanExactReplacement(path: path))
        }
        return replacements
    }

    /// Exact FSEvent paths do not benefit from FileManager enumerator resource
    /// prefetching. Reading their ordinary metadata with one `lstat` avoids a
    /// per-path LaunchServices lookup while retaining every field stored by the
    /// search index. Symlinks keep the Foundation path so their historic
    /// no-follow semantics remain identical.
    private static func scanExactReplacement(path: String) -> SearchIndexExactReplacement {
        var info = stat()
        let result = path.withCString { lstat($0, &info) }
        guard result == 0 else {
            let isMissing = errno == ENOENT || errno == ENOTDIR
            return SearchIndexExactReplacement(
                path: path,
                node: nil,
                isComplete: isMissing
            )
        }

        if (info.st_mode & S_IFMT) == S_IFLNK {
            let node = makeTempNode(url: URL(fileURLWithPath: path))
            return SearchIndexExactReplacement(
                path: path,
                node: node,
                isComplete: node != nil
            )
        }

        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        let isHiddenByName = components.contains { component in
            component.first == "." && component != "." && component != ".."
        }
        let isPackageDescendant = components.dropLast().contains { component in
            guard let dot = component.lastIndex(of: "."),
                  dot < component.index(before: component.endIndex) else { return false }
            let extensionStart = component.index(after: dot)
            return packageExtensions.contains(String(component[extensionStart...]).lowercased())
        }
        let modifiedTime = timeIntervalSinceReferenceDate(info.st_mtimespec)
        let rawCreationTime = timeIntervalSinceReferenceDate(info.st_birthtimespec)
        let node = TempNode(
            path: path,
            name: "",
            isDirectory: (info.st_mode & S_IFMT) == S_IFDIR,
            size: Int64(info.st_size),
            modifiedTime: modifiedTime,
            creationTime: info.st_birthtimespec.tv_sec > 0 ? rawCreationTime : modifiedTime,
            isHiddenScope: isHiddenByName || (info.st_flags & UInt32(UF_HIDDEN)) != 0,
            isPackageDescendant: isPackageDescendant
        )
        return SearchIndexExactReplacement(path: path, node: node)
    }

    private static func timeIntervalSinceReferenceDate(_ value: timespec) -> TimeInterval {
        TimeInterval(value.tv_sec)
            - Date.timeIntervalBetween1970AndReferenceDate
            + TimeInterval(value.tv_nsec) / 1_000_000_000
    }

    private static func scanReplacement(
        path: String,
        signature: SearchIndexSignature,
        ignoredPaths: [String],
        maximumNodes: Int? = nil
    ) async -> SearchIndexReplacement {
        let pausesForForegroundSearch = maximumNodes == nil
        if pausesForForegroundSearch {
            SearchWorkCoordinator.shared.waitForSearchesToFinish()
        }
        if maximumNodes == nil,
           let parallel = await scanBroadReplacement(
               path: path,
               signature: signature,
               ignoredPaths: ignoredPaths
           ) {
            return parallel
        }

        var nodes: [TempNode] = []
        let failedPaths = scanTempPath(
            path,
            signature: signature,
            ignoredPaths: ignoredPaths,
            maximumNodes: maximumNodes,
            pauseForForegroundSearch: pausesForForegroundSearch,
            into: &nodes
        )
        return SearchIndexReplacement(
            rootPath: path,
            nodes: deduplicatedTempNodes(nodes),
            preservedBaseRoots: collapseEventPaths(failedPaths, signature: signature)
        )
    }

    /// A subtree event can cover a large, volatile directory such as a home
    /// directory. The normal replacement scanner is intentionally simple and
    /// serial, which is ideal for small changes but can monopolize the process
    /// for a very large event backlog. Split only broad, uncapped replacements
    /// at their first level; every branch is still scanned completely and the
    /// root node is retained, so this changes scheduling rather than coverage.
    private static func scanBroadReplacement(
        path: String,
        signature: SearchIndexSignature,
        ignoredPaths: [String]
    ) async -> SearchIndexReplacement? {
        guard signature.contains(path: path),
              !isIgnored(path, ignoredPaths: ignoredPaths),
              let rootNode = makeTempNode(url: URL(fileURLWithPath: path)),
              rootNode.isDirectory else {
            return nil
        }

        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: path),
                includingPropertiesForKeys: resourceKeys,
                options: []
            )
        } catch {
            // Preserve the existing serial scanner's permission/error
            // semantics when the first-level listing itself is unavailable.
            return nil
        }

        let childPaths = children.compactMap { child -> String? in
            let childPath = SearchPath.normalize(child.path(percentEncoded: false))
            guard signature.contains(path: childPath),
                  !isIgnored(childPath, ignoredPaths: ignoredPaths) else {
                return nil
            }
            return childPath
        }
        guard childPaths.count >= 8 else { return nil }

        // A broad replacement can point at an iCloud tree with hundreds of
        // thousands of entries. Keep it single-worker and let foreground
        // searches temporarily pause it: reconciliation remains complete but
        // no longer monopolizes CPU, memory bandwidth, or filesystem caches.
        let workerCount = min(1, childPaths.count)
        var nextIndex = 0
        var nodes: [TempNode] = [rootNode]
        nodes.reserveCapacity(childPaths.count * 2)
        var failedPaths: [String] = []

        await withTaskGroup(of: ([TempNode], [String]).self) { group in
            for _ in 0..<workerCount {
                guard nextIndex < childPaths.count else { break }
                let childPath = childPaths[nextIndex]
                nextIndex += 1
                group.addTask {
                    var branchNodes: [TempNode] = []
                    let branchFailures = scanTempPath(
                        childPath,
                        signature: signature,
                        ignoredPaths: ignoredPaths,
                        pauseForForegroundSearch: true,
                        into: &branchNodes
                    )
                    return (branchNodes, branchFailures)
                }
            }

            while let result = await group.next() {
                nodes.append(contentsOf: result.0)
                failedPaths.append(contentsOf: result.1)
                guard nextIndex < childPaths.count else { continue }
                let childPath = childPaths[nextIndex]
                nextIndex += 1
                group.addTask {
                    var branchNodes: [TempNode] = []
                    let branchFailures = scanTempPath(
                        childPath,
                        signature: signature,
                        ignoredPaths: ignoredPaths,
                        pauseForForegroundSearch: true,
                        into: &branchNodes
                    )
                    return (branchNodes, branchFailures)
                }
            }
        }

        return SearchIndexReplacement(
            rootPath: path,
            nodes: deduplicatedTempNodes(nodes),
            preservedBaseRoots: collapseEventPaths(failedPaths, signature: signature)
        )
    }

    static func apply(eventPaths: [String], to index: SearchIndex, signature: SearchIndexSignature) async -> SearchIndex {
        let scanPaths = collapseEventPaths(eventPaths, signature: signature)
        guard !scanPaths.isEmpty, !Task.isCancelled else { return index }

        if scanPaths.contains(where: signature.scopes.contains) {
            return SearchIndex(
                signature: signature,
                nodes: await build(signature: signature),
                basePathsAreCanonicalUnique: true
            )
        }

        let replacements = await scanReplacements(paths: scanPaths, signature: signature)
        var tempNodes = index.toTempNodes()
        guard !Task.isCancelled else { return index }
        for replacement in replacements {
            let preservedRoots = Set(replacement.preservedBaseRoots)
            tempNodes.removeAll { node in
                let covered = SearchPath.hasNormalizedPrefix(node.path, of: replacement.rootPath)
                let preserved = node.path != replacement.rootPath
                    && isPath(node.path, coveredByRootPaths: preservedRoots)
                return covered && !preserved
            }
            tempNodes.append(contentsOf: replacement.nodes)
        }

        guard !Task.isCancelled else { return index }
        let uniqueTempNodes = deduplicatedTempNodes(tempNodes)

        return SearchIndex(
            signature: signature,
            nodes: assembleIndexedNodes(from: uniqueTempNodes),
            basePathsAreCanonicalUnique: true
        )
    }

    static func isPath(_ path: String, coveredBySortedPrefixes prefixes: [String]) -> Bool {
        prefixes.contains { SearchPath.hasNormalizedPrefix(path, of: $0) }
    }

    static func isPath(_ path: String, coveredByRootPaths roots: Set<String>) -> Bool {
        coveringRoot(for: path, in: roots) != nil
    }

    static func coveringRoot(for path: String, in roots: Set<String>) -> String? {
        guard !roots.isEmpty else { return nil }
        var candidate = path
        while true {
            if roots.contains(candidate) { return candidate }
            guard candidate != "/" else { return nil }
            let nextCandidate = SearchPath.parent(ofCanonicalPath: candidate)
            guard nextCandidate != candidate else { return nil }
            candidate = nextCandidate
        }
    }

    /// Converts already-deduplicated absolute-path nodes into the compact
    /// parent-linked representation. `/` is its own NSString parent, so it
    /// must remain parentless or every descendant path walk enters a cycle.
    static func assembleIndexedNodes(from uniqueTempNodes: [TempNode]) -> [IndexedFileNode] {
        var pathToIndex: [String: Int32] = [:]
        pathToIndex.reserveCapacity(uniqueTempNodes.count)
        for i in 0..<uniqueTempNodes.count {
            pathToIndex[uniqueTempNodes[i].path] = Int32(i)
        }

        var finalNodes: [IndexedFileNode] = []
        finalNodes.reserveCapacity(uniqueTempNodes.count)
        for node in uniqueTempNodes {
            let parentPath = (node.path as NSString).deletingLastPathComponent
            let parentIdx = parentPath == node.path ? -1 : (pathToIndex[parentPath] ?? -1)
            let nameToStore = (parentIdx == -1) ? node.path : node.name
            finalNodes.append(IndexedFileNode(
                name: nameToStore,
                parentIndex: parentIdx,
                isDirectory: node.isDirectory,
                size: node.size,
                modifiedTime: node.modifiedTime,
                creationTime: node.creationTime,
                isHiddenScope: node.isHiddenScope,
                isPackageDescendant: node.isPackageDescendant
            ))
        }
        return finalNodes
    }

    /// A transient metadata failure must not make a name/path candidate vanish
    /// between Stage 1 and Stage 2. The enriched scan remains authoritative for
    /// every completed path; only unresolved roots inherit missing topology from
    /// the query-ready snapshot and remain marked for retry.
    static func enrichedNodesPreservingQueryReadyCandidates(
        _ enrichedNodes: [IndexedFileNode],
        queryReadyIndex: SearchIndex?,
        unresolvedPaths: [String],
        signature: SearchIndexSignature
    ) -> [IndexedFileNode] {
        guard let queryReadyIndex, !unresolvedPaths.isEmpty else { return enrichedNodes }
        let unresolvedRoots = Set(unresolvedPaths.map(SearchPath.canonicalAliasPath))
        guard !unresolvedRoots.isEmpty else { return enrichedNodes }

        let preserved = queryReadyIndex.toTempNodes().filter { node in
            coveringRoot(for: SearchPath.canonicalAliasPath(node.path), in: unresolvedRoots) != nil
        }
        guard !preserved.isEmpty else { return enrichedNodes }

        var merged = SearchIndex(
            signature: signature,
            nodes: enrichedNodes,
            buildNameIndex: false,
            basePathsAreCanonicalUnique: true
        ).toTempNodes()
        merged.append(contentsOf: preserved)
        deduplicateTempNodesInPlace(&merged)
        return assembleIndexedNodes(from: merged)
    }

    static func collapseEventPaths(_ paths: [String], signature: SearchIndexSignature) -> [String] {
        let ignoredPaths = effectiveIgnoredPaths(for: signature)
        let scoped = Set(paths.lazy
            .map { SearchPath.canonicalAliasPath(SearchPath.normalize($0)) }
            .filter { path in
                signature.contains(path: path) && !isIgnored(path, ignoredPaths: ignoredPaths)
            })
        var ordered: [(path: String, depth: Int)] = []
        ordered.reserveCapacity(scoped.count)
        for path in scoped {
            ordered.append((path: path, depth: (path as NSString).pathComponents.count))
        }
        ordered.sort { lhs, rhs in
            lhs.depth == rhs.depth ? lhs.path < rhs.path : lhs.depth < rhs.depth
        }

        var selected: [String] = []
        selected.reserveCapacity(scoped.count)
        var selectedSet = Set<String>()
        selectedSet.reserveCapacity(scoped.count)
        for entry in ordered {
            var candidate = entry.path
            var isCovered = false
            while candidate != "/" {
                let parent = (candidate as NSString).deletingLastPathComponent
                candidate = parent.isEmpty ? "/" : parent
                if selectedSet.contains(candidate) {
                    isCovered = true
                    break
                }
            }
            guard !isCovered else { continue }
            selected.append(entry.path)
            selectedSet.insert(entry.path)
        }
        return selected.sorted()
    }

    static func canEnumerateDirectory(_ path: String) -> Bool {
        guard let directory = path.withCString({ opendir($0) }) else { return false }
        closedir(directory)
        return true
    }

    /// Collapses a large exact overlay only where changes are densely
    /// concentrated in a deep direct parent. This keeps the delta bounded
    /// without ever promoting a whole-Mac scope or a shallow home directory
    /// into an expensive subtree scan.
    static func exactOverlayCompactionRoots(
        paths: [String],
        signature: SearchIndexSignature,
        triggerCount: Int = 30_000,
        targetCount: Int = 20_000,
        minimumGroupSize: Int = 128,
        maximumRoots: Int = 8,
        pathsAreCanonical: Bool = false,
        pathsAreUnique: Bool = false
    ) -> [String] {
        guard paths.count > triggerCount, maximumRoots > 0 else { return [] }
        let normalizedPaths = (pathsAreCanonical
            ? paths
            : paths.map(SearchPath.canonicalAliasPath))
            .map { String(decoding: $0.utf8, as: UTF8.self) }
        let canonicalPaths = pathsAreUnique ? normalizedPaths : Array(Set(normalizedPaths))
        let scopeDepths = signature.scopes.map { scope in
            (
                scope,
                scope == "/" ? 0 : scope.utf8.reduce(into: 0) { depth, byte in
                    if byte == UInt8(ascii: "/") { depth += 1 }
                }
            )
        }
        var counts: [String: Int] = [:]

        for path in canonicalPaths {
            let parent = SearchPath.parent(ofCanonicalPath: path)
            guard !parent.isEmpty,
                  parent != path,
                  signature.containsCanonicalPath(parent),
                  !signature.scopes.contains(parent) else { continue }

            var coveringScope: (path: String, depth: Int)?
            for scope in scopeDepths where SearchPath.hasNormalizedPrefix(parent, of: scope.0) {
                if coveringScope == nil || scope.1 > coveringScope!.depth {
                    coveringScope = (scope.0, scope.1)
                }
            }
            guard let coveringScope else { continue }
            let parentDepth = parent.utf8.reduce(into: 0) { depth, byte in
                if byte == UInt8(ascii: "/") { depth += 1 }
            }
            let scopeDepth = coveringScope.depth
            let minimumRelativeDepth = coveringScope.path == "/" ? 6 : 3
            if parentDepth - scopeDepth < minimumRelativeDepth { continue }
            counts[parent, default: 0] += 1
        }

        let candidates = counts
            .filter { $0.value >= minimumGroupSize }
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }

        var selected: [String] = []
        for candidate in candidates {
            if selected.count >= maximumRoots { break }
            let proposed = collapseEventPaths(selected + [candidate.key], signature: signature)
            guard proposed.count <= maximumRoots else { continue }
            selected = proposed

            let remaining = canonicalPaths.reduce(into: 0) { count, path in
                if !isPath(path, coveredBySortedPrefixes: selected) { count += 1 }
            }
            if remaining <= targetCount { break }
        }
        return selected.sorted()
    }

    @discardableResult
    private static func scanTempPath(
        _ path: String,
        signature: SearchIndexSignature,
        ignoredPaths: [String],
        maximumNodes: Int? = nil,
        pauseForForegroundSearch: Bool = false,
        into nodes: inout [TempNode]
    ) -> [String] {
        guard signature.contains(path: path),
              !isIgnored(path, ignoredPaths: ignoredPaths) else { return [] }

        let url = URL(fileURLWithPath: path)
        guard let node = makeTempNode(url: url) else {
            return pathState(path) == .missing ? [] : [path]
        }
        nodes.append(node)
        var failedPaths = Set<String>()

        if node.isDirectory {
            let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: resourceKeys,
                options: [],
                errorHandler: { failedURL, error in
                    let failedPath = SearchPath.canonicalAliasPath(
                        failedURL.path(percentEncoded: false)
                    )
                    if shouldRetryScanFailure(error, path: failedPath) {
                        failedPaths.insert(failedPath)
                    }
                    return true
                }
            )
            guard let enumerator else { return [path] }
            while let item = enumerator.nextObject() as? URL {
                if Task.isCancelled { return Array(failedPaths) }
                if pauseForForegroundSearch, nodes.count.isMultiple(of: 256) {
                    SearchWorkCoordinator.shared.waitForSearchesToFinish()
                    if Task.isCancelled { return Array(failedPaths) }
                }
                if let maximumNodes, nodes.count >= maximumNodes {
                    return [path]
                }
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

                guard let itemNode = makeTempNode(url: item) else {
                    if pathState(itemPath) != .missing {
                        failedPaths.insert(SearchPath.canonicalAliasPath(itemPath))
                    }
                    continue
                }
                nodes.append(itemNode)
            }
        }
        return Array(failedPaths)
    }

    private static let resourceKeySet = Set(resourceKeys)

    private enum PathState {
        case exists
        case missing
        case unresolved
    }

    /// `fileExists` can report false for both ENOENT and denied/transient I/O.
    /// `lstat` lets exact-event handling create a tombstone only for an
    /// authoritative disappearance.
    private static func pathState(_ path: String) -> PathState {
        var info = stat()
        let result = path.withCString { lstat($0, &info) }
        if result == 0 { return .exists }
        switch errno {
        case ENOENT, ENOTDIR:
            return .missing
        default:
            return .unresolved
        }
    }

    private static func isPermissionDenied(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == NSFileReadNoPermissionError {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain,
           nsError.code == Int(EACCES) || nsError.code == Int(EPERM) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return underlying.domain == NSPOSIXErrorDomain
                && (underlying.code == Int(EACCES) || underlying.code == Int(EPERM))
        }
        return false
    }

    static func shouldRetryScanFailure(_ error: Error, path: String) -> Bool {
        !isPermissionDenied(error) && pathState(path) != .missing
    }

    @inline(__always)
    private static func recordScannedNode(
        _ node: TempNode,
        componentName: String,
        collected: inout [TempNode],
        pendingBatch: inout [TempNode],
        subdirectories: inout [ScanDirectory],
        localFiles: inout Int,
        localDirectories: inout Int,
        publishesPartialResults: Bool,
        ancestorIdentities: DirectoryIdentityChain?
    ) {
        collected.append(node)
        if publishesPartialResults { pendingBatch.append(node) }
        if node.isDirectory {
            localDirectories += 1
            subdirectories.append(ScanDirectory(
                path: node.path,
                descendantsAreHidden: node.isHiddenScope,
                descendantsArePackage: node.isPackageDescendant
                    || isPackageComponent(componentName),
                ancestorIdentities: ancestorIdentities
            ))
        } else {
            localFiles += 1
        }
    }

    @inline(__always)
    private static func isPackageComponent(_ component: String) -> Bool {
        packageExtensions.contains((component as NSString).pathExtension.lowercased())
    }

    private static func makeTempNode(url: URL) -> TempNode? {
        guard let values = try? url.resourceValues(forKeys: resourceKeySet) else { return nil }
        let path = SearchPath.canonicalAliasPath(url.path(percentEncoded: false))
        let isDirectory = values.isDirectory ?? false
        let size = Int64(values.fileSize ?? 0)
        let modified = values.contentModificationDate ?? .distantPast
        let created = values.creationDate ?? modified
        let components = url.pathComponents
        let isHidden = values.isHidden == true || components.contains { component in
            component.hasPrefix(".") && component != "." && component != ".."
        }
        let isPackageDescendant = components.dropLast().contains { component in
            packageExtensions.contains((component as NSString).pathExtension.lowercased())
        }

        return TempNode(
            path: path,
            name: url.lastPathComponent,
            isDirectory: isDirectory,
            size: size,
            modifiedTime: modified.timeIntervalSinceReferenceDate,
            creationTime: created.timeIntervalSinceReferenceDate,
            isHiddenScope: isHidden,
            isPackageDescendant: isPackageDescendant
        )
    }

    private static func queryReadyTempNode(_ node: TempNode) -> TempNode {
        TempNode(
            path: node.path,
            name: node.name,
            isDirectory: node.isDirectory,
            size: 0,
            modifiedTime: 0,
            creationTime: 0,
            isHiddenScope: node.isHiddenScope,
            isPackageDescendant: node.isPackageDescendant
        )
    }

    fileprivate static func deduplicatedTempNodes(_ nodes: [TempNode]) -> [TempNode] {
        var seen = Set<String>()
        seen.reserveCapacity(nodes.count)
        return nodes.filter { seen.insert(SearchPath.canonicalAliasPath($0.path)).inserted }
    }

    private static func deduplicateTempNodesInPlace(_ nodes: inout [TempNode]) {
        var seen = Set<String>()
        seen.reserveCapacity(nodes.count)
        nodes.removeAll { !seen.insert(SearchPath.canonicalAliasPath($0.path)).inserted }
    }

    static func effectiveIgnoredPaths(for signature: SearchIndexSignature) -> [String] {
        var base = signature.deepIndex ? SearchPath.deepIndexIgnoredPaths : SearchPath.defaultIgnoredPaths
        // Entering Desktop/Documents/Downloads directly triggers modal TCC
        // prompts. Whole-Mac indexing waits for Full Disk Access instead.
        if !signature.hasFullDiskAccess {
            base.append(contentsOf: SearchPath.protectedPrivacyPaths)
        }
        let privacyPaths = Set(SearchPath.protectedPrivacyPaths)
        return base.filter { ignored in
            let scopesThatMayOverride = privacyPaths.contains(ignored)
                ? signature.authorizedScopePaths
                : signature.scopes
            return !scopesThatMayOverride.contains { scope in
                SearchPath.hasNormalizedPrefix(scope, of: ignored)
            }
        }
    }

    fileprivate static func isIgnored(_ path: String, ignoredPaths: [String]) -> Bool {
        ignoredPaths.contains { SearchPath.hasNormalizedPrefix(path, of: $0) }
    }
}

enum SearchIndexPersistence {
    private static let magic = "OFIX"
    private static let compressedMagic = "OFZ1"
    private static let version: UInt32 = 18
    private static let deltaVersion = 4
    private static let maximumDeltaBytes = 128 * 1_024 * 1_024
    private static let maximumDeltaPaths = 500_000
    private static let nameIndexPersistenceLock = NSLock()

    struct Delta: Sendable {
        let subtreePaths: [String]
        let exactPaths: [String]
        let baseLastEventID: UInt64
        let lastEventID: UInt64
    }

    private struct PersistedDelta: Codable {
        let version: Int
        let signature: SearchIndexSignature
        let subtreePaths: [String]
        let exactPaths: [String]
        let baseLastEventID: UInt64
        let lastEventID: UInt64
    }

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
        let bytes: UnsafeRawBufferPointer
        var offset = 0

        init(bytes: UnsafeRawBufferPointer) {
            self.bytes = bytes
        }

        mutating func skip(_ count: Int) -> Bool {
            guard count >= 0, offset <= bytes.count, count <= bytes.count - offset else {
                return false
            }
            offset += count
            return true
        }

        mutating func readBytes(_ count: Int) -> [UInt8]? {
            guard offset + count <= bytes.count else { return nil }
            let value = Array(bytes[offset..<offset + count])
            offset += count
            return value
        }

        mutating func readUInt32() -> UInt32? {
            guard offset + 4 <= bytes.count else { return nil }
            let value = bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian
            offset += 4
            return value
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
            guard offset + 8 <= bytes.count else { return nil }
            let value = bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self).littleEndian
            offset += 8
            return value
        }

        mutating func readDouble() -> Double? {
            guard let val = readInt64() else { return nil }
            return Double(bitPattern: UInt64(bitPattern: val))
        }

        mutating func readUInt8() -> UInt8? {
            guard offset + 1 <= bytes.count else { return nil }
            let val = bytes[offset]
            offset += 1
            return val
        }

        mutating func readUInt16() -> UInt16? {
            guard offset + 2 <= bytes.count else { return nil }
            let value = bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self).littleEndian
            offset += 2
            return value
        }

        mutating func readString() -> String? {
            guard let len = readUInt16() else { return nil }
            let lenInt = Int(len)
            guard offset + lenInt <= bytes.count else { return nil }
            guard let baseAddress = bytes.baseAddress else { return lenInt == 0 ? "" : nil }
            let stringBytes = UnsafeBufferPointer(
                start: baseAddress.advanced(by: offset).assumingMemoryBound(to: UInt8.self),
                count: lenInt
            )
            offset += lenInt
            return String(bytes: stringBytes, encoding: .utf8)
        }
    }

    static func load(signature: SearchIndexSignature, from url: URL? = nil) -> SearchIndex? {
        let targetURL = url ?? cacheURL
        guard let storedData = try? Data(contentsOf: targetURL, options: .mappedIfSafe) else { return nil }
        let baseDigest = Data(SHA256.hash(data: storedData))
        if storedData.starts(with: compressedMagic.utf8) {
            guard let data = decompress(storedData) else { return nil }
            return decode(
                data,
                expectedSignature: signature,
                baseDigest: baseDigest,
                baseURL: targetURL
            )
        }
        // Raw OFIX v18 remains readable so the first optimized build can reuse
        // the user's existing index and compress it on the next safe save.
        return decode(
            storedData,
            expectedSignature: signature,
            baseDigest: baseDigest,
            baseURL: targetURL
        )
    }

    static func loadDelta(
        signature: SearchIndexSignature,
        baseLastEventID: UInt64?,
        from url: URL? = nil
    ) -> Delta? {
        let targetURL = deltaURL(for: url)
        guard let data = try? Data(contentsOf: targetURL, options: .mappedIfSafe),
              data.count <= maximumDeltaBytes,
              let persisted = try? PropertyListDecoder().decode(PersistedDelta.self, from: data),
              persisted.version == deltaVersion,
              persisted.signature == signature,
              persisted.baseLastEventID > 0,
              persisted.baseLastEventID == baseLastEventID,
              persisted.lastEventID > 0,
              persisted.subtreePaths.count + persisted.exactPaths.count <= maximumDeltaPaths,
              (persisted.subtreePaths + persisted.exactPaths).allSatisfy({ $0.utf8.count <= 4_096 }) else {
            return nil
        }

        let ignoredPaths = SearchIndexBuilder.effectiveIgnoredPaths(for: signature)
        let persistedSubtreePaths = persisted.subtreePaths.filter {
            !FileSystemEvent.isSyntheticDocumentIDPath($0)
        }
        let persistedExactPaths = persisted.exactPaths.filter {
            !FileSystemEvent.isSyntheticDocumentIDPath($0)
        }
        let subtreePaths = Array(Set(persistedSubtreePaths.map(SearchPath.canonicalAliasPath)))
            .filter { signature.contains(path: $0) && !SearchIndexBuilder.isIgnored($0, ignoredPaths: ignoredPaths) }
            .sorted()
        let exactPaths = Array(Set(persistedExactPaths.map(SearchPath.canonicalAliasPath)))
            .filter { signature.contains(path: $0) && !SearchIndexBuilder.isIgnored($0, ignoredPaths: ignoredPaths) }
            .sorted()
        guard subtreePaths.sorted() == persistedSubtreePaths.sorted(),
              exactPaths == persistedExactPaths.sorted() else {
            return nil
        }
        return Delta(
            subtreePaths: subtreePaths,
            exactPaths: exactPaths,
            baseLastEventID: persisted.baseLastEventID,
            lastEventID: persisted.lastEventID
        )
    }

    static func saveDelta(
        signature: SearchIndexSignature,
        rootPaths: [String],
        baseLastEventID: UInt64,
        lastEventID: UInt64,
        to url: URL? = nil
    ) {
        saveDelta(
            signature: signature,
            subtreePaths: rootPaths,
            exactPaths: [],
            baseLastEventID: baseLastEventID,
            lastEventID: lastEventID,
            to: url
        )
    }

    static func saveDelta(
        signature: SearchIndexSignature,
        subtreePaths: [String],
        exactPaths: [String],
        baseLastEventID: UInt64,
        lastEventID: UInt64,
        to url: URL? = nil
    ) {
        guard baseLastEventID > 0, lastEventID >= baseLastEventID else { return }
        let collapsedSubtreePaths = SearchIndexBuilder.collapseEventPaths(subtreePaths, signature: signature)
        let ignoredPaths = SearchIndexBuilder.effectiveIgnoredPaths(for: signature)
        let canonicalExactPaths = Array(Set(exactPaths.map(SearchPath.canonicalAliasPath)))
            .filter { signature.contains(path: $0) && !SearchIndexBuilder.isIgnored($0, ignoredPaths: ignoredPaths) }
            .sorted()
        writeDelta(
            signature: signature,
            subtreePaths: collapsedSubtreePaths,
            exactPaths: canonicalExactPaths,
            baseLastEventID: baseLastEventID,
            lastEventID: lastEventID,
            to: url
        )
    }

    /// The store owns canonical, unique replacement keys already. Avoid
    /// re-normalizing tens of thousands of unchanged paths on every journal
    /// checkpoint; `loadDelta` still validates the persisted boundary.
    static func saveCanonicalDelta(
        signature: SearchIndexSignature,
        subtreePaths: [String],
        exactPaths: [String],
        baseLastEventID: UInt64,
        lastEventID: UInt64,
        to url: URL? = nil
    ) {
        guard baseLastEventID > 0, lastEventID >= baseLastEventID else { return }
        writeDelta(
            signature: signature,
            subtreePaths: preparedCanonicalDeltaPaths(subtreePaths),
            exactPaths: preparedCanonicalDeltaPaths(exactPaths),
            baseLastEventID: baseLastEventID,
            lastEventID: lastEventID,
            to: url
        )
    }

    /// Event replacement keys are already canonical. Rebuild them as native
    /// Swift strings before hashing/sorting so paths originating in Foundation
    /// do not retain bridged NSString storage through every journal checkpoint.
    private static func preparedCanonicalDeltaPaths(_ paths: [String]) -> [String] {
        var unique: Set<String> = []
        unique.reserveCapacity(paths.count)
        for path in paths {
            unique.insert(String(decoding: path.utf8, as: UTF8.self))
        }
        return unique.sorted()
    }

    private static func writeDelta(
        signature: SearchIndexSignature,
        subtreePaths: [String],
        exactPaths: [String],
        baseLastEventID: UInt64,
        lastEventID: UInt64,
        to url: URL?
    ) {
        let persisted = PersistedDelta(
            version: deltaVersion,
            signature: signature,
            subtreePaths: subtreePaths.filter {
                !FileSystemEvent.isSyntheticDocumentIDPath($0)
            },
            exactPaths: exactPaths.filter {
                !FileSystemEvent.isSyntheticDocumentIDPath($0)
            },
            baseLastEventID: baseLastEventID,
            lastEventID: lastEventID
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(persisted) else { return }

        let targetURL = deltaURL(for: url)
        do {
            try FileManager.default.createDirectory(
                at: targetURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: targetURL, options: .atomic)
        } catch {
            // A stale journal only causes safe event replay on the next launch.
        }
    }

    static func deltaURL(for url: URL? = nil) -> URL {
        let targetURL = url ?? cacheURL
        return targetURL.deletingPathExtension().appendingPathExtension("delta.plist")
    }

    static func nameIndexURL(for url: URL? = nil) -> URL {
        let targetURL = url ?? cacheURL
        return targetURL.deletingPathExtension().appendingPathExtension("names-v1.bin")
    }

    /// Cache writes are visible in the event log but must not feed the index
    /// journal back into itself. MarkSelf identifies atomic temporary files;
    /// exact base/delta paths are also filtered during historical replay.
    static func isInternalIndexEvent(path: String, flags: UInt32, baseURL: URL? = nil) -> Bool {
        let targetURL = baseURL ?? cacheURL
        let canonicalPath = SearchPath.canonicalAliasPath(path)
        let basePath = SearchPath.canonicalAliasPath(targetURL.path(percentEncoded: false))
        let deltaPath = SearchPath.canonicalAliasPath(deltaURL(for: targetURL).path(percentEncoded: false))
        let nameIndexPath = SearchPath.canonicalAliasPath(
            nameIndexURL(for: targetURL).path(percentEncoded: false)
        )
        if canonicalPath == basePath
            || canonicalPath == deltaPath
            || canonicalPath == nameIndexPath
            || ContentSearchIndex.isDatabaseEvent(path: canonicalPath, indexURL: targetURL) {
            return true
        }

        let ownEvent = (FSEventStreamEventFlags(flags)
            & FSEventStreamEventFlags(kFSEventStreamEventFlagOwnEvent)) != 0
        guard ownEvent else { return false }
        let eventParent = (canonicalPath as NSString).deletingLastPathComponent
        let persistenceParent = (basePath as NSString).deletingLastPathComponent
        return eventParent == persistenceParent
    }

    static func save(
        index: SearchIndex,
        to url: URL? = nil,
        removeDelta: Bool = true
    ) {
        let rawData = encode(index)
        let data = compress(rawData) ?? rawData
        let targetURL = url ?? cacheURL
        let baseDigest = Data(SHA256.hash(data: data))
        let nameIndexData = index.nameIndexForPersistence()?.sidecarData(
            baseDigest: baseDigest
        )
        nameIndexPersistenceLock.lock()
        defer { nameIndexPersistenceLock.unlock() }
        do {
            try FileManager.default.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: targetURL, options: .atomic)
            if let nameIndexData {
                try nameIndexData.write(to: nameIndexURL(for: targetURL), options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: nameIndexURL(for: targetURL))
            }
            if removeDelta {
                try? FileManager.default.removeItem(at: deltaURL(for: targetURL))
            }

            for legacyVersion in 1...17 {
                let legacyName = legacyVersion == 1
                    ? "search-index-v1.plist"
                    : "search-index-v\(legacyVersion).bin"
                let oldURL = targetURL.deletingLastPathComponent()
                    .appendingPathComponent(legacyName)
                let oldStem = oldURL.deletingPathExtension()
                let artifacts = [
                    oldURL,
                    oldStem.appendingPathExtension("delta.plist"),
                    oldStem.appendingPathExtension("names-v1.bin"),
                    oldStem.appendingPathExtension("content-v1.sqlite3"),
                    URL(fileURLWithPath: oldStem.path + ".content-v1.sqlite3-wal"),
                    URL(fileURLWithPath: oldStem.path + ".content-v1.sqlite3-shm"),
                ]
                for artifact in artifacts {
                    try? FileManager.default.removeItem(at: artifact)
                }
            }
        } catch {
            // Cache persistence failure should not break search
        }
    }

    private static func persistBuiltNameIndex(
        _ nameIndex: SearchNameIndex,
        baseDigest: Data,
        baseURL: URL
    ) {
        guard let sidecarData = nameIndex.sidecarData(baseDigest: baseDigest) else { return }
        nameIndexPersistenceLock.lock()
        defer { nameIndexPersistenceLock.unlock() }
        guard let currentBase = try? Data(contentsOf: baseURL, options: .mappedIfSafe),
              Data(SHA256.hash(data: currentBase)) == baseDigest else { return }
        try? sidecarData.write(to: nameIndexURL(for: baseURL), options: .atomic)
    }

    static var cacheURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("OpenFind", isDirectory: true)
            .appendingPathComponent("search-index-v18.bin")
    }

    private static func encode(_ index: SearchIndex) -> Data {
        var writer = BinaryWriter()
        writer.data.reserveCapacity(68 + index.nodes.count * 33)
        writer.write(bytes: Array(magic.utf8))
        writer.write(version)
        writer.write(UInt8(index.signature.deepIndex ? 1 : 0))
        writer.write(UInt8(index.signature.hasFullDiskAccess ? 1 : 0))
        writer.write(UInt32(index.signature.scopes.count))
        writer.write(UInt32(index.signature.authorizedScopePaths.count))
        writer.write(UInt32(index.unresolvedPaths.count))
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
        let authorizedScopeIndices = index.signature.authorizedScopePaths.map { getStringIndex($0) }
        let unresolvedPathIndices = index.unresolvedPaths.map { getStringIndex($0) }

        for idx in scopeIndices {
            writer.write(idx)
        }
        for idx in authorizedScopeIndices {
            writer.write(idx)
        }
        for idx in unresolvedPathIndices {
            writer.write(idx)
        }

        for node in index.nodes {
            var flags: UInt8 = 0
            if node.isDirectory { flags |= 1 }
            if node.isHiddenScope { flags |= 2 }
            if node.isPackageDescendant { flags |= 4 }
            writer.write(node.parentIndex)
            writer.write(getStringIndex(node.name))
            writer.write(flags)
            writer.write(node.size)
            writer.write(node.modifiedTime)
            writer.write(node.creationTime)
        }

        writer.write(UInt32(stringPool.count))
        for str in stringPool {
            writer.write(str)
        }

        return writer.data
    }

    /// LZFSE keeps the compact string-pool/node format but reduces the durable
    /// whole-Mac snapshot to approximately its compressed working set. The
    /// envelope is optional: incompressible or failed encodes fall back to the
    /// existing raw OFIX representation without affecting correctness.
    private static func compress(_ rawData: Data) -> Data? {
        guard rawData.count >= 64 * 1_024 else { return nil }
        let extraCapacity = max(64 * 1_024, rawData.count / 16)
        let (capacity, overflow) = rawData.count.addingReportingOverflow(extraCapacity)
        guard !overflow else { return nil }
        var compressed = Data(count: capacity)
        let scratchSize = compression_encode_scratch_buffer_size(COMPRESSION_LZFSE)
        let scratch = scratchSize > 0
            ? UnsafeMutableRawPointer.allocate(byteCount: scratchSize, alignment: 16)
            : nil
        defer { scratch?.deallocate() }

        let encodedSize = rawData.withUnsafeBytes { source in
            compressed.withUnsafeMutableBytes { destination in
                guard let sourceAddress = source.baseAddress,
                      let destinationAddress = destination.baseAddress else { return 0 }
                return compression_encode_buffer(
                    destinationAddress.assumingMemoryBound(to: UInt8.self),
                    capacity,
                    sourceAddress.assumingMemoryBound(to: UInt8.self),
                    rawData.count,
                    scratch,
                    COMPRESSION_LZFSE
                )
            }
        }
        let headerBytes = 12
        guard encodedSize > 0, encodedSize + headerBytes < rawData.count else { return nil }
        compressed.removeSubrange(encodedSize..<compressed.count)

        var writer = BinaryWriter()
        writer.data.reserveCapacity(headerBytes + encodedSize)
        writer.write(bytes: Array(compressedMagic.utf8))
        writer.write(UInt64(rawData.count))
        writer.data.append(compressed)
        return writer.data
    }

    private static func decompress(_ storedData: Data) -> Data? {
        let headerBytes = 12
        guard storedData.count > headerBytes else { return nil }
        let decodedByteCount: UInt64? = storedData.withUnsafeBytes { bytes in
            guard bytes.count >= headerBytes else { return nil }
            return bytes.loadUnaligned(fromByteOffset: 4, as: UInt64.self).littleEndian
        }
        let maximumDecodedBytes = 2 * 1_024 * 1_024 * 1_024
        guard let decodedByteCount,
              decodedByteCount > 0,
              decodedByteCount <= UInt64(maximumDecodedBytes),
              decodedByteCount <= UInt64(Int.max) else { return nil }

        var decoded = Data(count: Int(decodedByteCount))
        let decodedSize = storedData.withUnsafeBytes { source in
            decoded.withUnsafeMutableBytes { destination in
                guard let sourceAddress = source.baseAddress,
                      let destinationAddress = destination.baseAddress else { return 0 }
                return compression_decode_buffer(
                    destinationAddress.assumingMemoryBound(to: UInt8.self),
                    destination.count,
                    sourceAddress.advanced(by: headerBytes).assumingMemoryBound(to: UInt8.self),
                    source.count - headerBytes,
                    nil,
                    COMPRESSION_LZFSE
                )
            }
        }
        return decodedSize == decoded.count ? decoded : nil
    }

    private static func decode(
        _ data: Data,
        expectedSignature: SearchIndexSignature,
        baseDigest: Data,
        baseURL: URL
    ) -> SearchIndex? {
        data.withUnsafeBytes { bytes in
            decode(
                bytes,
                expectedSignature: expectedSignature,
                baseDigest: baseDigest,
                baseURL: baseURL
            )
        }
    }

    private static func decode(
        _ bytes: UnsafeRawBufferPointer,
        expectedSignature: SearchIndexSignature,
        baseDigest: Data,
        baseURL: URL
    ) -> SearchIndex? {
        var reader = BinaryReader(bytes: bytes)

        guard let magicBytes = reader.readBytes(4),
              String(bytes: magicBytes, encoding: .utf8) == magic else { return nil }

        guard let ver = reader.readUInt32(), ver == version else { return nil }
        guard let deepIndexByte = reader.readUInt8() else { return nil }
        guard let fullDiskAccessByte = reader.readUInt8() else { return nil }
        guard let scopesCount = reader.readUInt32() else { return nil }
        guard let authorizedScopesCount = reader.readUInt32(),
              authorizedScopesCount <= scopesCount else { return nil }
        guard let unresolvedPathsCount = reader.readUInt32(), unresolvedPathsCount <= 1_000_000 else { return nil }
        guard let nodesCount = reader.readUInt32() else { return nil }
        guard let encodedLastEventID = reader.readUInt64() else { return nil }

        var scopeIndices: [UInt32] = []
        for _ in 0..<scopesCount {
            guard let idx = reader.readUInt32() else { return nil }
            scopeIndices.append(idx)
        }
        var authorizedScopeIndices: [UInt32] = []
        authorizedScopeIndices.reserveCapacity(Int(authorizedScopesCount))
        for _ in 0..<authorizedScopesCount {
            guard let idx = reader.readUInt32() else { return nil }
            authorizedScopeIndices.append(idx)
        }
        var unresolvedPathIndices: [UInt32] = []
        unresolvedPathIndices.reserveCapacity(Int(unresolvedPathsCount))
        for _ in 0..<unresolvedPathsCount {
            guard let idx = reader.readUInt32() else { return nil }
            unresolvedPathIndices.append(idx)
        }

        let nodesOffset = reader.offset
        let (encodedNodesBytes, nodeByteCountOverflow) = Int(nodesCount)
            .multipliedReportingOverflow(by: 33)
        guard !nodeByteCountOverflow, reader.skip(encodedNodesBytes) else { return nil }

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
        var authorizedScopePaths: [String] = []
        authorizedScopePaths.reserveCapacity(authorizedScopeIndices.count)
        for idx in authorizedScopeIndices {
            guard idx < stringPool.count else { return nil }
            authorizedScopePaths.append(stringPool[Int(idx)])
        }
        var unresolvedPaths: [String] = []
        unresolvedPaths.reserveCapacity(unresolvedPathIndices.count)
        for idx in unresolvedPathIndices {
            guard idx < stringPool.count else { return nil }
            unresolvedPaths.append(stringPool[Int(idx)])
        }

        let loadedSignature = SearchIndexSignature(
            scopes: scopes.map { URL(fileURLWithPath: $0) },
            deepIndex: deepIndexByte == 1,
            hasFullDiskAccess: fullDiskAccessByte == 1,
            authorizedScopePaths: authorizedScopePaths
        )
        guard loadedSignature == expectedSignature else { return nil }
        let canonicalUnresolvedPaths = SearchIndexBuilder.collapseEventPaths(
            unresolvedPaths,
            signature: loadedSignature
        )
        guard canonicalUnresolvedPaths.sorted() == unresolvedPaths.sorted() else { return nil }

        var nodes: [IndexedFileNode] = []
        nodes.reserveCapacity(Int(nodesCount))
        reader.offset = nodesOffset

        for nodeIndex in 0..<Int(nodesCount) {
            guard let parentIndex = reader.readInt32(),
                  let nameIndex = reader.readUInt32(),
                  let flags = reader.readUInt8(),
                  let size = reader.readInt64(),
                  let modifiedTime = reader.readDouble(),
                  let creationTime = reader.readDouble(),
                  nameIndex < stringPool.count else { return nil }
            guard parentIndex == -1 || (
                parentIndex >= 0
                    && Int(parentIndex) < Int(nodesCount)
                    && Int(parentIndex) != nodeIndex
            ) else { return nil }
            let name = stringPool[Int(nameIndex)]
            let isDir = (flags & 1) != 0
            let isHidden = (flags & 2) != 0
            let isPkg = (flags & 4) != 0

            nodes.append(IndexedFileNode(
                name: name,
                parentIndex: parentIndex,
                isDirectory: isDir,
                size: size,
                modifiedTime: modifiedTime,
                creationTime: creationTime,
                isHiddenScope: isHidden,
                isPackageDescendant: isPkg
            ))
        }

        let persistedNameIndex = SearchNameIndex.loadMapped(
            nodes: nodes,
            baseDigest: baseDigest,
            from: nameIndexURL(for: baseURL)
        )
        return SearchIndex(
            signature: loadedSignature,
            nodes: nodes,
            lastEventID: encodedLastEventID == 0 ? nil : encodedLastEventID,
            unresolvedPaths: canonicalUnresolvedPaths,
            deferNameIndexBuild: true,
            initialNameIndex: persistedNameIndex,
            persistBuiltNameIndex: { nameIndex in
                SearchIndexPersistence.persistBuiltNameIndex(
                    nameIndex,
                    baseDigest: baseDigest,
                    baseURL: baseURL
                )
            },
            basePathsAreCanonicalUnique: true
        )
    }
}

enum SearchPath {
    private static let dataVolumePath = "/System/Volumes/Data"
    private static let noFollowPath = "/.nofollow"
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

    static func existsWithoutFollowingSymlinks(_ path: String) -> Bool {
        var info = stat()
        return path.withCString { lstat($0, &info) } == 0
    }

    static var defaultIgnoredPaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        return pathAliases([
            dataVolumePath,
            noFollowPath,
            // Device nodes and /dev/fd entries are process-local pseudo-files,
            // not durable searchable content. Enumerating them can leave stale
            // descriptors queued for retry after they disappear.
            "/dev",
            "/Volumes/.timemachine",
            "/Volumes/Recovery",
            "/Volumes/com.apple.TimeMachine.localsnapshots",
            "\(home)/Library/Biome",
            "\(home)/Library/Caches",
            "\(home)/Library/Logs",
            "\(home)/Library/Metadata",
            "/Library/Caches",
            "/System/Library/Caches",
            "/private/var",
            "/private/tmp",
        ])
    }

    /// Minimal ignore list for deep indexing: aliases of the root filesystem
    /// that would otherwise traverse and index the same nodes again, plus the
    /// dynamic device pseudo-filesystem which contains no persistent user data.
    static var deepIndexIgnoredPaths: [String] {
        pathAliases([dataVolumePath, noFollowPath, "/dev"])
    }

    static var protectedPrivacyPaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        return pathAliases([
            "/Volumes",
            "\(home)/Desktop",
            "\(home)/Documents",
            "\(home)/Downloads",
            "\(home)/Music",
            "\(home)/Movies",
            "\(home)/Pictures",
            "\(home)/Library/Mail",
            "\(home)/Library/Messages",
            "\(home)/Library/Safari",
            "\(home)/Library/Calendars",
            "\(home)/Library/Application Support/AddressBook",
        ])
    }

    private static func pathAliases(_ paths: [String]) -> [String] {
        Array(Set(paths.flatMap { path in [path, normalize(path)] })).sorted()
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

    static func canonicalAliasPath(_ path: String) -> String {
        let normalized = normalize(path)
        let pathWithoutNoFollow: String
        if normalized == noFollowPath {
            pathWithoutNoFollow = "/"
        } else if hasNormalizedPrefix(normalized, of: noFollowPath) {
            pathWithoutNoFollow = String(normalized.dropFirst(noFollowPath.count))
        } else {
            pathWithoutNoFollow = normalized
        }

        guard pathWithoutNoFollow != dataVolumePath,
              hasNormalizedPrefix(pathWithoutNoFollow, of: dataVolumePath) else {
            return pathWithoutNoFollow
        }

        let suffix = pathWithoutNoFollow.dropFirst(dataVolumePath.count)
        guard suffix.first == "/" else { return pathWithoutNoFollow }
        let alias = String(suffix)
        guard let topLevel = alias.dropFirst().split(separator: "/", maxSplits: 1).first else {
            return pathWithoutNoFollow
        }
        let root = "/" + String(topLevel)
        return dataVolumeAliasRoots.contains(root) ? alias : pathWithoutNoFollow
    }

    /// Appends one validated directory-entry name to an already canonical
    /// scanner path. Only the three alias roots need the full URL-based
    /// canonicalizer; every descendant can use a lossless string append.
    @inline(__always)
    static func appendingCanonicalComponent(_ component: String, to parent: String) -> String {
        let joined = parent == "/" ? "/\(component)" : "\(parent)/\(component)"
        if parent == "/private" || parent == dataVolumePath || parent == noFollowPath {
            return canonicalAliasPath(joined)
        }
        return joined
    }

    static func parent(ofCanonicalPath path: String) -> String {
        guard path != "/" else { return "/" }
        let bytes = path.utf8
        guard let slash = bytes.lastIndex(of: UInt8(ascii: "/")) else { return "/" }
        if slash == bytes.startIndex { return "/" }
        return String(decoding: bytes[..<slash], as: UTF8.self)
    }

    /// Paths emitted by the durable index and its replacement scanners are
    /// already absolute and normalized.  Most of them cannot be affected by
    /// alias canonicalization, so avoid the repeated URL/substring
    /// normalization pass on the hot name-search path.  The few prefixes that
    /// can change (`/private`, `.nofollow`, and the Data-volume mirror) use the
    /// full canonicalizer to preserve exact deduplication semantics.
    static func canonicalIndexedPath(_ path: String) -> String {
        guard path != "/" else { return path }
        if path.hasPrefix("/private/")
            || path == noFollowPath
            || path.hasPrefix(noFollowPath + "/")
            || path == dataVolumePath
            || path.hasPrefix(dataVolumePath + "/") {
            return canonicalAliasPath(path)
        }
        return path
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
        if string.utf8.allSatisfy({ $0 < 0xE3 }) { return false }
        return string.unicodeScalars.contains(where: isHanScalar)
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

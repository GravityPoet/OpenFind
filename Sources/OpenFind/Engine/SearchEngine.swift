import Foundation

/// Gives latency-sensitive searches precedence over large event-reconciliation
/// scans. The filesystem scan is paused, not cancelled, so no indexed path or
/// eventual event update is dropped.
final class SearchWorkCoordinator: @unchecked Sendable {
    static let shared = SearchWorkCoordinator()

    private let condition = NSCondition()
    private var activeSearchCount = 0

    func beginSearch() {
        condition.lock()
        activeSearchCount += 1
        condition.unlock()
    }

    func endSearch() {
        condition.lock()
        activeSearchCount = max(0, activeSearchCount - 1)
        if activeSearchCount == 0 {
            condition.broadcast()
        }
        condition.unlock()
    }

    func waitForSearchesToFinish() {
        condition.lock()
        while activeSearchCount > 0, !Task.isCancelled {
            condition.wait(until: Date(timeIntervalSinceNow: 0.05))
        }
        condition.unlock()
    }
}

private actor ContentSearchMemoryGate {
    private struct Waiter {
        let bytes: Int64
        let continuation: CheckedContinuation<Int64, Never>
    }

    private let capacity: Int64
    private var available: Int64
    private var waiters: [Waiter] = []

    init(capacity: Int64) {
        self.capacity = max(1, capacity)
        available = max(1, capacity)
    }

    func acquire(_ requestedBytes: Int64) async -> Int64 {
        let bytes = min(capacity, max(1, requestedBytes))
        if waiters.isEmpty, bytes <= available {
            available -= bytes
            return bytes
        }
        return await withCheckedContinuation { continuation in
            waiters.append(Waiter(bytes: bytes, continuation: continuation))
        }
    }

    func release(_ bytes: Int64) {
        available = min(capacity, available + min(capacity, max(1, bytes)))
        while let waiter = waiters.first, waiter.bytes <= available {
            waiters.removeFirst()
            available -= waiter.bytes
            waiter.continuation.resume(returning: waiter.bytes)
        }
    }
}

/// Complete, relevance-ordered name matches kept in their compact indexed
/// representation. The GUI materializes only the visible page into
/// `SearchResult`; the untouched tail remains fully available for pagination.
private enum SearchNameResultStorage: Sendable {
    case resolved([ResolvedNode])
    case compact(SearchIndexCompactNameMatches)

    var count: Int {
        switch self {
        case .resolved(let nodes): nodes.count
        case .compact(let matches): matches.count
        }
    }

    func node(at index: Int) -> ResolvedNode {
        switch self {
        case .resolved(let nodes): nodes[index]
        case .compact(let matches): matches.node(at: index)
        }
    }
}

struct SearchNameResultSnapshot: Sendable {
    private let storage: SearchNameResultStorage
    fileprivate let validationIndex: SearchIndex?

    var count: Int { storage.count }
    var usesCompactReferences: Bool {
        if case .compact = storage { return true }
        return false
    }
    var bytesPerStoredMatch: Int {
        usesCompactReferences
            ? MemoryLayout<Int32>.stride
            : MemoryLayout<ResolvedNode>.stride
    }

    init(nodes: [ResolvedNode], validationIndex: SearchIndex?) {
        storage = .resolved(nodes)
        self.validationIndex = validationIndex
    }

    init(compactMatches: SearchIndexCompactNameMatches, validationIndex: SearchIndex?) {
        storage = .compact(compactMatches)
        self.validationIndex = validationIndex
    }

    fileprivate func node(at index: Int) -> ResolvedNode {
        storage.node(at: index)
    }
}

struct SearchNameResultPage: Sendable {
    let results: [SearchResult]
    /// Raw snapshot offset after the last inspected node. This can be greater
    /// than `results.count` when excluded or stale nodes were skipped.
    let nextOffset: Int
    let staleResultCount: Int
}

/// Indexed search engine.
///
/// Search roots are scanned into a persistent path/name index by
/// `SearchIndexStore`. Name searches run entirely against that in-memory
/// snapshot. Content searches still read file contents on demand, but they now
/// use indexed files as candidates instead of walking the filesystem for every
/// query. Results stream out through an `AsyncStream` so the UI can display
/// them as they arrive. Cancellation propagates through `Task`.
enum SearchEngine {

    static func supportsCompactNameSnapshot(options: SearchOptions) -> Bool {
        guard options.target == .name,
              let compiledQuery = try? SearchQueryPlan.parse(options.query).compile(options: options) else {
            return false
        }
        return !compiledQuery.shouldRunContentBranch(options: options)
    }

    /// Fast GUI path for a pure name search. Unlike the general stream, this
    /// transfers one compact ordered snapshot and does not construct millions
    /// of display rows that SwiftUI cannot show yet.
    static func nameResultSnapshot(
        scopes: [URL],
        options: SearchOptions,
        store: SearchIndexStore = .shared
    ) async -> SearchNameResultSnapshot? {
        guard options.target == .name else { return nil }

        let compiledQuery: CompiledSearchQuery
        do {
            compiledQuery = try SearchQueryPlan.parse(options.query).compile(options: options)
        } catch {
            return nil
        }
        guard !compiledQuery.shouldRunContentBranch(options: options) else { return nil }

        let index = await store.snapshot(
            for: scopes,
            deepIndex: options.deepIndex,
            hasFullDiskAccess: SearchPermissions.hasFullDiskAccess(),
            requiringCompleteMetadata: compiledQuery.requiresCompleteMetadata(options: options)
        )
        guard !Task.isCancelled else { return nil }

        SearchWorkCoordinator.shared.beginSearch()
        defer { SearchWorkCoordinator.shared.endSearch() }
        let usageSnapshot = options.useFrequencyRanking
            ? SearchUsageStore.shared.snapshot()
            : nil
        if let matches = index.compactNameMatches(
            query: compiledQuery,
            options: options,
            usageSnapshot: usageSnapshot
        ) {
            guard !Task.isCancelled else { return nil }
            return SearchNameResultSnapshot(
                compactMatches: matches,
                validationIndex: index.requiresAnyExistenceValidation ? index : nil
            )
        }
        let nodes = index.nameMatches(
            query: compiledQuery,
            options: options,
            usageSnapshot: usageSnapshot
        )
        guard !Task.isCancelled else { return nil }
        return SearchNameResultSnapshot(
            nodes: nodes,
            validationIndex: index.requiresAnyExistenceValidation ? index : nil
        )
    }

    /// Converts at most one visible page. Existence checks are restricted to
    /// nodes inspected for that page; a million-row tail is neither traversed
    /// nor discarded. Stale or explicitly excluded nodes are skipped and the
    /// page is filled from subsequent candidates when possible.
    static func materializeNamePage(
        from snapshot: SearchNameResultSnapshot,
        startingAt rawOffset: Int,
        count requestedCount: Int,
        excluding excludedIdentities: Set<ResolvedNodeIdentity> = []
    ) async -> SearchNameResultPage {
        let requestedCount = max(0, requestedCount)
        var offset = min(max(0, rawOffset), snapshot.count)
        guard requestedCount > 0, offset < snapshot.count else {
            return SearchNameResultPage(results: [], nextOffset: offset, staleResultCount: 0)
        }

        var results: [SearchResult] = []
        results.reserveCapacity(min(requestedCount, snapshot.count - offset))
        var staleResultCount = 0

        while results.count < requestedCount, offset < snapshot.count {
            if Task.isCancelled { break }
            let needed = requestedCount - results.count
            var candidates: [ResolvedNode] = []
            candidates.reserveCapacity(needed)
            while candidates.count < needed, offset < snapshot.count {
                let node = snapshot.node(at: offset)
                offset += 1
                if !excludedIdentities.contains(node.identity) {
                    candidates.append(node)
                }
            }
            guard !candidates.isEmpty else { continue }

            let existing = if let validationIndex = snapshot.validationIndex {
                await existingNodes(in: candidates[...], validationIndex: validationIndex)
            } else {
                candidates
            }
            staleResultCount += candidates.count - existing.count
            for node in existing {
                if Task.isCancelled { break }
                results.append(node.searchResult(matchedContent: false, preview: nil))
            }
        }

        return SearchNameResultPage(
            results: results,
            nextOffset: offset,
            staleResultCount: staleResultCount
        )
    }

    /// Starts a search and returns an incremental result stream. The underlying
    /// traversal is cancelled automatically when the consumer stops iterating or
    /// the stream is otherwise terminated.
    static func search(scopes: [URL], options: SearchOptions, store: SearchIndexStore = .shared) -> AsyncStream<SearchResult> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task(priority: .userInitiated) {
                for await batch in searchBatches(scopes: scopes, options: options, store: store) {
                    if Task.isCancelled { break }
                    for result in batch {
                        if Task.isCancelled { break }
                        continuation.yield(result)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Native batch stream used by the GUI and CLI.  A whole-Mac query can
    /// legitimately return millions of rows; crossing the AsyncStream lock and
    /// allocator once per row dominated the otherwise-fast indexed lookup.
    /// Batching changes transport only: ordering and every result are kept.
    static func searchBatches(
        scopes: [URL],
        options: SearchOptions,
        store: SearchIndexStore = .shared
    ) -> AsyncStream<[SearchResult]> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task.detached(priority: .userInitiated) {
                await run(scopes: scopes, options: options, store: store, continuation: continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func run(
        scopes: [URL],
        options: SearchOptions,
        store: SearchIndexStore,
        continuation: AsyncStream<[SearchResult]>.Continuation
    ) async {
        let compiledQuery: CompiledSearchQuery
        do {
            compiledQuery = try SearchQueryPlan.parse(options.query).compile(options: options)
        } catch {
            return // Empty query or invalid regex: finish silently; the UI guards empty queries.
        }

        let index = await store.snapshot(
            for: scopes,
            deepIndex: options.deepIndex,
            hasFullDiskAccess: SearchPermissions.hasFullDiskAccess(),
            requiringCompleteMetadata: compiledQuery.requiresCompleteMetadata(options: options)
        )
        // Acquire foreground priority only after a query-ready snapshot exists.
        // Doing this before `snapshot` can deadlock a cold launch whose cache
        // recovery is itself waiting for background permission; doing it after
        // the first result lets that recovery delay the most visible latency.
        SearchWorkCoordinator.shared.beginSearch()
        defer { SearchWorkCoordinator.shared.endSearch() }
        // A completed scan has already read metadata for every indexed node.
        // The event watcher revokes this fast path as soon as a filesystem
        // change is observed, so broad queries avoid millions of redundant
        // lstat calls without reducing the indexed scope or result set.
        let validationIndex = index.requiresAnyExistenceValidation ? index : nil

        var nameHitPaths = Set<String>()
        if options.target != .content {
            let needsNameHitPaths = compiledQuery.shouldRunContentBranch(options: options)
            // Rank the complete match set once, then publish it in that exact
            // order. The former early-page pass searched the index twice and
            // could pin 2,000 index-order hits ahead of globally more relevant
            // matches. The compact ID result representation makes one complete
            // pass both faster and semantically correct.
            let completeResults = index.nameMatches(
                query: compiledQuery,
                options: options,
                usageSnapshot: options.useFrequencyRanking
                    ? SearchUsageStore.shared.snapshot()
                    : nil
            )
            let completeValidationIndex = shouldValidateCompleteNameTail(completeResults.count)
                ? validationIndex
                : nil
            let paths = await yieldExistingNodes(
                completeResults,
                collectingPaths: needsNameHitPaths,
                validationIndex: completeValidationIndex,
                continuation: continuation
            )
            nameHitPaths.formUnion(paths)
        }

        guard compiledQuery.shouldRunContentBranch(options: options) else { return }

        let candidates = index.contentCandidates(query: compiledQuery, options: options, excluding: nameHitPaths)
        if !compiledQuery.requiresContentScan(options: options) {
            var offset = 0
            while offset < candidates.count {
                if Task.isCancelled { return }
                let end = min(offset + existenceCheckBatchSize, candidates.count)
                let batch = candidates[offset..<end]
                let existing = if let validationIndex {
                    await existingNodes(in: batch, validationIndex: validationIndex)
                } else {
                    Array(batch)
                }
                var resultBatch: [SearchResult] = []
                resultBatch.reserveCapacity(existing.count)
                for node in existing {
                    if Task.isCancelled { return }
                    resultBatch.append(node.searchResult(matchedContent: false, preview: nil))
                }
                if !resultBatch.isEmpty { continuation.yield(resultBatch) }
                offset = end
            }
            return
        }
        let contentIndex = await store.contentIndexHandle()
        let indexedPlan = await contentIndex.plan(
            candidates: candidates.map {
                ContentIndexCandidate(
                    node: $0,
                    forceRefresh: index.requiresExistenceValidation(for: $0.path)
                )
            },
            requiredLiteral: compiledQuery.requiredContentIndexTerm(options: options)
        )
        await searchContents(
            workItems: indexedPlan.workItems,
            query: compiledQuery,
            options: options,
            contentIndex: contentIndex,
            continuation: continuation
        )
    }

    /// `lstat` is needed to discard paths deleted after the index snapshot,
    /// but doing it serially turns a broad query into millions of round trips.
    /// Results are checked in bounded batches and each batch uses a fixed
    /// number of workers rather than allocating one Swift task per path.
    private static let existenceCheckBatchSize = max(
        256,
        min(1_024, ProcessInfo.processInfo.activeProcessorCount * 64)
    )
    /// Once a broad tail no longer needs per-path filesystem validation, use
    /// larger transport batches. This preserves every result while avoiding
    /// thousands of cross-actor/UI handoffs for million-match queries.
    private static let resultTransportBatchSize = 16_384
    static let maximumFullyValidatedNameMatches = 25_000

    /// Content decoding can temporarily hold both mapped bytes and a decoded
    /// String. Workers share this budget, so selecting 1 GB or No Limit does
    /// not let every CPU core materialize a huge file at the same time.
    static var contentSearchMemoryBudgetBytes: Int64 {
        let physicalBytes = min(UInt64(Int64.max), ProcessInfo.processInfo.physicalMemory)
        let oneSixteenth = Int64(physicalBytes / 16)
        return min(1 * 1_024 * 1_024 * 1_024, max(256 * 1_024 * 1_024, oneSixteenth))
    }

    static func estimatedContentMemoryBytes(fileSize: Int64, budget: Int64) -> Int64 {
        let minimumReservation: Int64 = 1 * 1_024 * 1_024
        let normalizedBudget = max(minimumReservation, budget)
        let normalizedSize = max(1, fileSize)
        let (scaledSize, overflow) = normalizedSize.multipliedReportingOverflow(by: 3)
        let estimate = overflow ? normalizedBudget : scaledSize
        return min(normalizedBudget, max(minimumReservation, estimate))
    }

    static func shouldValidateCompleteNameTail(_ matchCount: Int) -> Bool {
        matchCount <= maximumFullyValidatedNameMatches
    }

    private static func yieldExistingNodes(
        _ nodes: [ResolvedNode],
        excluding excludedIdentities: Set<ResolvedNodeIdentity> = [],
        collectingPaths: Bool,
        validationIndex: SearchIndex?,
        continuation: AsyncStream<[SearchResult]>.Continuation
    ) async -> Set<String> {
        var emittedPaths = Set<String>()
        if collectingPaths {
            emittedPaths.reserveCapacity(min(nodes.count, 100_000))
        }
        let batchSize = validationIndex == nil
            ? resultTransportBatchSize
            : existenceCheckBatchSize
        var offset = 0
        while offset < nodes.count {
            if Task.isCancelled { return emittedPaths }
            let end = min(offset + batchSize, nodes.count)
            var candidates: [ResolvedNode] = []
            candidates.reserveCapacity(end - offset)
            for node in nodes[offset..<end] {
                if !excludedIdentities.contains(node.identity) {
                    candidates.append(node)
                }
            }
            let existing = if let validationIndex {
                await existingNodes(in: candidates[...], validationIndex: validationIndex)
            } else {
                candidates
            }
            var resultBatch: [SearchResult] = []
            resultBatch.reserveCapacity(existing.count)
            for node in existing {
                if Task.isCancelled { return emittedPaths }
                if collectingPaths {
                    emittedPaths.insert(SearchPath.canonicalIndexedPath(node.path))
                }
                resultBatch.append(node.searchResult(matchedContent: false, preview: nil))
            }
            if !resultBatch.isEmpty { continuation.yield(resultBatch) }
            offset = end
        }
        return emittedPaths
    }

    private static func existingNodes(
        in nodes: ArraySlice<ResolvedNode>,
        validationIndex: SearchIndex
    ) async -> [ResolvedNode] {
        guard !nodes.isEmpty else { return [] }
        let indexedNodes = Array(nodes)
        var existing = [ResolvedNode?](repeating: nil, count: indexedNodes.count)
        var validationOffsets: [Int] = []
        validationOffsets.reserveCapacity(indexedNodes.count)

        for (offset, node) in indexedNodes.enumerated() {
            if validationIndex.requiresExistenceValidation(for: node.path) {
                validationOffsets.append(offset)
            } else {
                existing[offset] = node
            }
        }

        let workerCount = min(
            validationOffsets.count,
            max(4, ProcessInfo.processInfo.activeProcessorCount * 2)
        )
        guard workerCount > 0 else { return existing.compactMap { $0 } }
        let chunkSize = (validationOffsets.count + workerCount - 1) / workerCount

        await withTaskGroup(of: [Int].self) { group in
            for start in stride(from: 0, to: validationOffsets.count, by: chunkSize) {
                let end = min(start + chunkSize, validationOffsets.count)
                let offsets = Array(validationOffsets[start..<end])
                group.addTask {
                    var liveOffsets: [Int] = []
                    liveOffsets.reserveCapacity(offsets.count)
                    for offset in offsets {
                        guard !Task.isCancelled else { break }
                        if SearchPath.existsWithoutFollowingSymlinks(indexedNodes[offset].path) {
                            liveOffsets.append(offset)
                        }
                    }
                    return liveOffsets
                }
            }
            for await liveOffsets in group {
                for offset in liveOffsets {
                    existing[offset] = indexedNodes[offset]
                }
            }
        }

        return existing.compactMap { $0 }
    }

    private struct ContentScanOutcome: Sendable {
        let record: ContentIndexRecord?
        let result: SearchResult?
        let reservation: Int64
    }

    private static func searchContents(
        workItems: [ContentIndexWorkItem],
        query: CompiledSearchQuery,
        options: SearchOptions,
        contentIndex: ContentSearchIndex,
        continuation: AsyncStream<[SearchResult]>.Continuation
    ) async {
        let maxConcurrency = max(4, ProcessInfo.processInfo.activeProcessorCount * 2)
        let memoryBudget = contentSearchMemoryBudgetBytes
        let memoryGate = ContentSearchMemoryGate(capacity: memoryBudget)
        var resultBatch: [SearchResult] = []
        resultBatch.reserveCapacity(64)
        var pendingRecords: [ContentIndexRecord] = []
        var pendingRecordBytes = 0

        func publishIfNeeded(force: Bool = false) {
            guard !resultBatch.isEmpty, force || resultBatch.count >= 64 else { return }
            continuation.yield(resultBatch)
            resultBatch.removeAll(keepingCapacity: true)
        }

        func flushRecordsIfNeeded(force: Bool = false) async {
            guard !pendingRecords.isEmpty,
                  force || pendingRecords.count >= 128 || pendingRecordBytes >= 32 * 1_024 * 1_024 else {
                return
            }
            let records = pendingRecords
            pendingRecords.removeAll(keepingCapacity: true)
            pendingRecordBytes = 0
            await contentIndex.record(
                records,
                maximumDatabaseBytes: options.maxContentIndexBytes
            )
        }

        func consume(_ outcome: ContentScanOutcome) async {
            if let result = outcome.result {
                resultBatch.append(result)
                publishIfNeeded()
            }
            if let record = outcome.record {
                pendingRecordBytes += record.text?.utf8.count ?? 0
                pendingRecords.append(record)
                // The shared gate bounds concurrent extraction. Once a result
                // has been reduced to its retained String, the separate 32 MB
                // SQLite batch limit accounts for it; holding the extraction
                // reservation until 128 records arrive can deadlock when a few
                // expandable documents consume the entire gate.
                await memoryGate.release(outcome.reservation)
                await flushRecordsIfNeeded()
            } else {
                await memoryGate.release(outcome.reservation)
            }
        }

        await withTaskGroup(of: ContentScanOutcome.self) { group in
            var inFlight = 0

            for item in workItems {
                if Task.isCancelled { return }

                while inFlight >= maxConcurrency {
                    if let outcome = await group.next() { await consume(outcome) }
                    inFlight -= 1
                }

                inFlight += 1
                group.addTask {
                    let node = item.node
                    if Task.isCancelled {
                        return ContentScanOutcome(record: nil, result: nil, reservation: 1)
                    }
                    let estimatedInputSize: Int64
                    if DocumentTextExtractor.mayExpandDuringExtraction(name: node.name) {
                        estimatedInputSize = options.maxContentFileSize == 0
                            ? memoryBudget
                            : options.maxContentFileSize
                    } else {
                        estimatedInputSize = node.size
                    }
                    let reservation = await memoryGate.acquire(
                        estimatedContentMemoryBytes(fileSize: estimatedInputSize, budget: memoryBudget)
                    )
                    if Task.isCancelled {
                        return ContentScanOutcome(record: nil, result: nil, reservation: reservation)
                    }
                    let inspection = autoreleasepool {
                        ContentMatcher.inspect(in: node, query: query, options: options)
                    }
                    let result = inspection.match.map {
                        node.searchResult(matchedContent: true, preview: $0.preview)
                    }
                    let shouldRecord = item.shouldRecord || inspection.match == nil
                    let record: ContentIndexRecord?
                    if shouldRecord, let text = inspection.extractedText {
                        record = ContentIndexRecord(node: node, text: text)
                    } else if shouldRecord,
                              DocumentTextExtractor.isStableNonTextFile(
                                node.url,
                                maxFileSize: options.maxContentFileSize
                              ) {
                        record = ContentIndexRecord(node: node, text: nil)
                    } else {
                        record = nil
                    }
                    return ContentScanOutcome(
                        record: record,
                        result: result,
                        reservation: reservation
                    )
                }
            }

            while let outcome = await group.next() {
                await consume(outcome)
            }
        }
        await flushRecordsIfNeeded(force: true)
        publishIfNeeded(force: true)
    }
}

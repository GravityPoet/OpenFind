import Foundation

/// Indexed search engine.
///
/// Search roots are scanned into a persistent path/name index by
/// `SearchIndexStore`. Name searches run entirely against that in-memory
/// snapshot. Content searches still read file contents on demand, but they now
/// use indexed files as candidates instead of walking the filesystem for every
/// query. Results stream out through an `AsyncStream` so the UI can display
/// them as they arrive. Cancellation propagates through `Task`.
enum SearchEngine {

    /// Starts a search and returns an incremental result stream. The underlying
    /// traversal is cancelled automatically when the consumer stops iterating or
    /// the stream is otherwise terminated.
    static func search(scopes: [URL], options: SearchOptions) -> AsyncStream<SearchResult> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task.detached(priority: .userInitiated) {
                await run(scopes: scopes, options: options, continuation: continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func run(
        scopes: [URL],
        options: SearchOptions,
        continuation: AsyncStream<SearchResult>.Continuation
    ) async {
        let compiledQuery: CompiledSearchQuery
        do {
            compiledQuery = try SearchQueryPlan.parse(options.query).compile(options: options)
        } catch {
            return // Empty query or invalid regex: finish silently; the UI guards empty queries.
        }

        let index = await SearchIndexStore.shared.snapshot(for: scopes)

        var nameHitPaths = Set<String>()
        if options.target != .content {
            let nameResults = index.nameMatches(query: compiledQuery, options: options)
            for node in nameResults {
                if Task.isCancelled { return }
                nameHitPaths.insert(node.path)
                continuation.yield(node.searchResult(matchedContent: false, preview: nil))
            }
        }

        guard compiledQuery.shouldRunContentBranch(options: options) else { return }

        let candidates = index.contentCandidates(query: compiledQuery, options: options, excluding: nameHitPaths)
        let contentMatchers = compiledQuery.contentMatchers(for: options)
        if contentMatchers.isEmpty {
            for node in candidates {
                if Task.isCancelled { return }
                continuation.yield(node.searchResult(matchedContent: false, preview: nil))
            }
            return
        }
        await searchContents(candidates: candidates, matchers: contentMatchers, options: options, continuation: continuation)
    }

    private static func searchContents(
        candidates: [IndexedFileNode],
        matchers: [Matcher],
        options: SearchOptions,
        continuation: AsyncStream<SearchResult>.Continuation
    ) async {
        let maxConcurrency = max(4, ProcessInfo.processInfo.activeProcessorCount * 2)

        await withTaskGroup(of: SearchResult?.self) { group in
            var inFlight = 0

            for node in candidates {
                if Task.isCancelled { return }

                while inFlight >= maxConcurrency {
                    if let result = await group.next(), let result {
                        continuation.yield(result)
                    }
                    inFlight -= 1
                }

                inFlight += 1
                let maxSize = options.maxContentFileSize
                group.addTask {
                    if Task.isCancelled { return nil }
                    guard let preview = ContentMatcher.firstMatchingLine(in: node.url, matchers: matchers, maxSize: maxSize)
                    else { return nil }
                    return node.searchResult(matchedContent: true, preview: preview)
                }
            }

            while let result = await group.next() {
                if let result {
                    continuation.yield(result)
                }
            }
        }
    }
}

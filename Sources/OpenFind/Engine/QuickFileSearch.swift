import Foundation

enum QuickFileSearch {
    static func options(for query: String, using preferences: SearchOptions) -> SearchOptions? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // Keep the launcher predictable and cheap. Content prefixes,
        // boolean expressions, and metadata filters belong to Full Search.
        guard !trimmed.isEmpty, !trimmed.contains(":"), !trimmed.contains("/"),
              !trimmed.contains("\n") else { return nil }
        var options = preferences
        options.query = trimmed
        options.target = .name
        options.matchMode = .substring
        options.caseSensitive = false
        options.includePackages = false
        guard let compiled = try? SearchQueryPlan.parse(trimmed).compile(options: options),
              !compiled.shouldRunContentBranch(options: options),
              !compiled.requiresCompleteMetadata(options: options) else { return nil }
        return options
    }

    static func search(
        scopes: [URL], options: SearchOptions, store: SearchIndexStore, limit: Int = 50
    ) async -> QuickSearchFileResponse {
        guard let snapshot = await SearchEngine.nameResultSnapshot(scopes: scopes, options: options, store: store),
              !Task.isCancelled else { return QuickSearchFileResponse() }
        var results: [SearchResult] = []
        var offset = 0
        let limit = max(1, limit)
        // Materialize bounded pages; further matches remain reachable through
        // Load More instead of being confused with the nine number shortcuts.
        while results.count <= limit, offset < snapshot.count, !Task.isCancelled {
            let page = await SearchEngine.materializeNamePage(from: snapshot, startingAt: offset, count: 64)
            guard page.nextOffset > offset else { break }
            offset = page.nextOffset
            results.append(contentsOf: page.results.filter { $0.url.pathExtension.lowercased() != "app" })
        }
        let stats = await store.stats()
        return QuickSearchFileResponse(results: Array(results.prefix(limit)), isIndexing: stats.isIndexing,
                                       hasMore: results.count > limit || offset < snapshot.count)
    }
}

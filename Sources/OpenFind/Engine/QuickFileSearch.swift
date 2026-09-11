import Foundation

enum QuickFileSearch {
    static func options(for query: String, using preferences: SearchOptions) -> SearchOptions? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // Keep the launcher predictable and cheap. Prefixes, wildcards,
        // boolean expressions, and metadata filters belong to Full Search.
        guard !trimmed.isEmpty, !trimmed.contains(":"), !trimmed.contains("/"),
              !trimmed.contains("*"), !trimmed.contains("?") else { return nil }
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
        scopes: [URL], options: SearchOptions, store: SearchIndexStore
    ) async -> QuickSearchFileResponse {
        guard let snapshot = await SearchEngine.nameResultSnapshot(scopes: scopes, options: options, store: store),
              !Task.isCancelled else { return QuickSearchFileResponse() }
        var results: [SearchResult] = []
        var offset = 0
        // Only materialize the short visible list. Package helpers stay out of
        // the launcher; the main search continues to expose the complete set.
        while results.count < 9, offset < snapshot.count, offset < 128, !Task.isCancelled {
            let page = await SearchEngine.materializeNamePage(from: snapshot, startingAt: offset, count: 24)
            guard page.nextOffset > offset else { break }
            offset = page.nextOffset
            results.append(contentsOf: page.results.filter { $0.url.pathExtension.lowercased() != "app" })
        }
        let stats = await store.stats()
        return QuickSearchFileResponse(results: Array(results.prefix(9)), isIndexing: stats.isIndexing)
    }
}

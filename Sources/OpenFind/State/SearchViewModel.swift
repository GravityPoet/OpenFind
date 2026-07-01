import Foundation
import Observation

/// UI state and search lifecycle. All state lives on the main actor and is
/// observed directly by SwiftUI. Durable options and search scopes are loaded
/// on init and persisted as they change.
@MainActor
@Observable
final class SearchViewModel {

    var options: SearchOptions
    var scopes: [URL]
    var results: [SearchResult] = []
    var recentSearches: [String]

    var isSearching = false
    var elapsed: TimeInterval = 0
    /// Set once the result limit is reached, so the UI can flag truncation.
    var truncated = false

    /// UI-side cap on result count, to keep the list responsive on huge hits.
    private let resultLimit = 20_000
    private var searchTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var startedAt: Date?

    init() {
        options = Preferences.loadOptions()
        let stored = ScopeStore.load()
        scopes = stored.isEmpty ? [FileManager.default.homeDirectoryForCurrentUser] : stored
        recentSearches = Preferences.recentSearches
    }

    var canSearch: Bool {
        !options.query.trimmingCharacters(in: .whitespaces).isEmpty && !scopes.isEmpty
    }

    var resultCount: Int { results.count }

    /// Debounced trigger for query/option changes: search only fires after
    /// 350 ms without further changes. Durable options are persisted here.
    func scheduleSearch(delay: Duration = .milliseconds(350)) {
        Preferences.saveOptions(options)
        debounceTask?.cancel()
        guard canSearch else {
            cancel()
            results = []
            return
        }
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.startSearch()
        }
    }

    /// Starts a new search, cancelling any previous one.
    func startSearch() {
        guard canSearch else { return }
        debounceTask?.cancel()
        cancel()

        recordRecentSearch()
        let currentOptions = options
        let currentScopes = scopes
        results = []
        truncated = false
        isSearching = true
        elapsed = 0
        startedAt = Date()

        searchTask = Task { [weak self] in
            await self?.consume(scopes: currentScopes, options: currentOptions)
        }
    }

    /// Cancels the current search, keeping any results already found.
    func cancel() {
        searchTask?.cancel()
        searchTask = nil
        if isSearching { finish() }
    }

    func addScope(_ url: URL) {
        guard !scopes.contains(url) else { return }
        scopes.append(url)
        ScopeStore.save(scopes)
    }

    func removeScopes(_ offsets: IndexSet) {
        for index in offsets where scopes.indices.contains(index) {
            ScopeStore.releaseAccess(scopes[index])
        }
        scopes.remove(atOffsets: offsets)
        ScopeStore.save(scopes)
    }

    func applyRecentSearch(_ query: String) {
        options.query = query
        startSearch()
    }

    func clearRecentSearches() {
        Preferences.clearRecentSearches()
        recentSearches = []
    }

    private func recordRecentSearch() {
        Preferences.addRecentSearch(options.query)
        recentSearches = Preferences.recentSearches
    }

    private func consume(scopes: [URL], options: SearchOptions) async {
        var pending: [SearchResult] = []
        pending.reserveCapacity(64)

        let stream = SearchEngine.search(scopes: scopes, options: options)
        for await result in stream {
            if Task.isCancelled { break }
            pending.append(result)
            if pending.count >= 48 {
                flush(&pending)
                if truncated { break }
            }
        }
        flush(&pending)
        if !Task.isCancelled { finish() }
    }

    /// Merges a buffered batch into `results`, truncating at the limit.
    private func flush(_ pending: inout [SearchResult]) {
        guard !pending.isEmpty else { return }
        let remaining = resultLimit - results.count
        if remaining <= 0 {
            truncated = true
            pending.removeAll(keepingCapacity: true)
            return
        }
        if pending.count > remaining {
            results.append(contentsOf: pending.prefix(remaining))
            truncated = true
        } else {
            results.append(contentsOf: pending)
        }
        pending.removeAll(keepingCapacity: true)
        if let startedAt { elapsed = Date().timeIntervalSince(startedAt) }
    }

    private func finish() {
        isSearching = false
        if let startedAt { elapsed = Date().timeIntervalSince(startedAt) }
    }
}

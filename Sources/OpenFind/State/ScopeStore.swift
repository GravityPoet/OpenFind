import Foundation

/// Persists user-selected folders as security-scoped bookmarks so access
/// survives relaunch. This is required under App Sandbox and harmless outside
/// it (the scoped-access calls are simply no-ops when unsandboxed).
enum ScopeStore {
    // UserDefaults is thread-safe; the annotation documents that guarantee.
    nonisolated(unsafe) private static let defaults = UserDefaults.standard
    private static let key = "search.scopeBookmarks"

    /// Resolves persisted bookmarks to URLs, starting security-scoped access.
    /// Unresolvable bookmarks are dropped; stale ones are refreshed. Returns an
    /// empty array when nothing is stored.
    static func load() -> [URL] {
        guard let stored = defaults.array(forKey: key) as? [Data] else { return [] }
        var urls: [URL] = []
        var refreshed: [Data] = []
        for data in stored {
            var isStale = false
            guard let url = try? URL(resolvingBookmarkData: data,
                                     options: [.withSecurityScope],
                                     relativeTo: nil,
                                     bookmarkDataIsStale: &isStale) else { continue }
            _ = url.startAccessingSecurityScopedResource()
            urls.append(url)
            if isStale, let fresh = try? url.bookmarkData(options: [.withSecurityScope]) {
                refreshed.append(fresh)
            } else {
                refreshed.append(data)
            }
        }
        defaults.set(refreshed, forKey: key)
        return urls
    }

    /// Persists the given URLs as security-scoped bookmarks, replacing any prior set.
    static func save(_ urls: [URL]) {
        let data = urls.compactMap { try? $0.bookmarkData(options: [.withSecurityScope]) }
        defaults.set(data, forKey: key)
    }

    /// Relinquishes security-scoped access for a URL that is being removed.
    static func releaseAccess(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }
}

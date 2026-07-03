import Foundation

enum SearchScopes {
    static let wholeMacPath = "/"
    static let legacyWholeMacPath = "/System/Volumes/Data"
    static let wholeMacURL = URL(fileURLWithPath: wholeMacPath)

    static func isWholeMac(_ url: URL) -> Bool {
        let path = normalizedPath(url)
        return path == wholeMacPath || path == legacyWholeMacPath
    }

    static func normalized(_ url: URL) -> URL {
        isWholeMac(url) ? wholeMacURL : url
    }

    static func isWholeMacOnly(_ urls: [URL]) -> Bool {
        urls.count == 1 && urls.contains(where: isWholeMac)
    }

    static func adding(_ url: URL, to scopes: [URL]) -> [URL] {
        let normalizedURL = normalized(url)
        if isWholeMac(normalizedURL) {
            return [wholeMacURL]
        }

        var customScopes = scopes
            .map(normalized)
            .filter { !isWholeMac($0) }
        guard !customScopes.contains(normalizedURL) else { return customScopes }
        customScopes.append(normalizedURL)
        return customScopes
    }

    private static func normalizedPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        guard path != wholeMacPath else { return wholeMacPath }
        return path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}

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
            let normalizedURL = SearchScopes.normalized(url)
            urls.append(normalizedURL)
            if (isStale || normalizedURL != url),
               let fresh = try? normalizedURL.bookmarkData(options: [.withSecurityScope]) {
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
        let normalized = urls.map(SearchScopes.normalized)
        let data = normalized.compactMap { try? $0.bookmarkData(options: [.withSecurityScope]) }
        defaults.set(data, forKey: key)
    }

    /// Relinquishes security-scoped access for a URL that is being removed.
    static func releaseAccess(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }
}

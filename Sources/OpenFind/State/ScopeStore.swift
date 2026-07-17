import Foundation

enum SearchScopes {
    static let wholeMacPath = "/"
    static let legacyWholeMacPath = "/System/Volumes/Data"
    static let wholeMacURL = URL(fileURLWithPath: wholeMacPath)

    static func isWholeMac(_ url: URL) -> Bool {
        let path = SearchPath.canonicalAliasPath(normalizedPath(url))
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
    private static let authorizationLock = NSLock()
    nonisolated(unsafe) private static var authorizedPaths = Set<String>()
    private static let key = "search.scopeBookmarks"

    /// Resolves persisted bookmarks to URLs, starting security-scoped access.
    /// Unresolvable bookmarks are dropped; stale ones are refreshed. Returns an
    /// empty array when nothing is stored.
    static func load() -> [URL] {
        guard let stored = defaults.array(forKey: key) as? [Data] else {
            replaceAuthorizedPaths([])
            return []
        }
        var urls: [URL] = []
        var refreshed: [Data] = []
        var resolvedAuthorizedPaths: [String] = []
        for data in stored {
            var isStale = false
            guard let url = try? URL(resolvingBookmarkData: data,
                                     options: [.withSecurityScope],
                                     relativeTo: nil,
                                     bookmarkDataIsStale: &isStale) else { continue }
            _ = url.startAccessingSecurityScopedResource()
            let normalizedURL = SearchScopes.normalized(url)
            urls.append(normalizedURL)
            if !SearchScopes.isWholeMac(normalizedURL) {
                resolvedAuthorizedPaths.append(canonicalPath(normalizedURL))
            }
            if (isStale || normalizedURL != url),
               let fresh = try? normalizedURL.bookmarkData(options: [.withSecurityScope]) {
                refreshed.append(fresh)
            } else {
                refreshed.append(data)
            }
        }
        defaults.set(refreshed, forKey: key)
        replaceAuthorizedPaths(resolvedAuthorizedPaths)
        return urls
    }

    /// Persists the given URLs as security-scoped bookmarks, replacing any prior set.
    static func save(_ urls: [URL]) {
        let normalized = urls.map(SearchScopes.normalized)
        var data: [Data] = []
        var savedAuthorizedPaths: [String] = []
        for url in normalized {
            guard let bookmark = try? url.bookmarkData(options: [.withSecurityScope]) else {
                continue
            }
            data.append(bookmark)
            if !SearchScopes.isWholeMac(url) {
                savedAuthorizedPaths.append(canonicalPath(url))
            }
        }
        defaults.set(data, forKey: key)
        replaceAuthorizedPaths(savedAuthorizedPaths)
    }

    /// Relinquishes security-scoped access for a URL that is being removed.
    static func releaseAccess(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
        authorizationLock.lock()
        authorizedPaths.remove(canonicalPath(url))
        authorizationLock.unlock()
    }

    static func authorizedScopePaths(for urls: [URL]) -> [String] {
        let requested = Set(urls
            .filter { !SearchScopes.isWholeMac($0) }
            .map(canonicalPath))
        authorizationLock.lock()
        let matching = authorizedPaths.intersection(requested).sorted()
        authorizationLock.unlock()
        return matching
    }

    private static func replaceAuthorizedPaths(_ paths: [String]) {
        authorizationLock.lock()
        authorizedPaths = Set(paths)
        authorizationLock.unlock()
    }

    private static func canonicalPath(_ url: URL) -> String {
        SearchPath.canonicalAliasPath(url.path(percentEncoded: false))
    }
}

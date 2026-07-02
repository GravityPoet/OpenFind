import Foundation

/// Prevents accidental no-index content scans over very broad roots.
enum SearchScopeGuard {
    static func needsBroadContentConfirmation(options: SearchOptions, scopes: [URL]) -> Bool {
        guard options.target != .name else { return false }
        return scopes.contains(where: isBroadScope)
    }

    private static func isBroadScope(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let homePath = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        return path == "/" || path == "/Users" || path == homePath
    }
}

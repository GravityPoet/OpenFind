import Foundation

/// Fast, app-only search for the Alfred-style launcher. This intentionally has
/// a separate cache from the file index: app discovery is small, predictable,
/// and can be refreshed in the background without delaying the first frame.
actor ApplicationSearchIndex {
    static let shared = ApplicationSearchIndex()

    private var cachedResults: [ApplicationSearchResult] = []
    private var lastRefresh: Date?
    private var refreshTask: Task<[ApplicationSearchResult], Never>?
    private let refreshInterval: TimeInterval = 15

    func prewarm() async {
        _ = await results(for: "")
    }

    func results(for query: String) async -> [ApplicationSearchResult] {
        await refreshIfNeeded()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return ApplicationSearchMatcher.rank(
            trimmed,
            in: cachedResults,
            usage: SearchUsageStore.shared.snapshot()
        )
    }

    /// Kept internal for deterministic matcher tests without touching the
    /// user's application list.
    static func rank(
        _ query: String,
        in candidates: [ApplicationSearchResult]
    ) -> [ApplicationSearchResult] {
        ApplicationSearchMatcher.rank(query, in: candidates)
    }

    private func refreshIfNeeded() async {
        if let lastRefresh,
           !cachedResults.isEmpty,
           Date().timeIntervalSince(lastRefresh) < refreshInterval {
            return
        }
        if let refreshTask {
            cachedResults = await refreshTask.value
            self.refreshTask = nil
            lastRefresh = Date()
            return
        }
        let task = Task.detached(priority: .utility) {
            Self.discoverApplications()
        }
        refreshTask = task
        cachedResults = await task.value
        refreshTask = nil
        lastRefresh = Date()
    }

    nonisolated static var applicationRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/Applications",
            "\(home)/Applications",
            "/System/Applications",
            "/System/Library/CoreServices/Applications",
            "/System/Library/CoreServices/Finder.app",
        ].map { URL(fileURLWithPath: $0) }
    }

    nonisolated static func discoverApplications(roots: [URL] = applicationRoots) -> [ApplicationSearchResult] {
        var bestByBundleID: [String: ApplicationSearchResult] = [:]
        var unbundled: [URL: ApplicationSearchResult] = [:]
        let fileManager = FileManager.default

        for root in roots {
            if root.pathExtension.lowercased() == "app" {
                if let result = applicationResult(at: root), let id = result.bundleIdentifier {
                    bestByBundleID[id] = bestByBundleID[id] ?? result
                }
                continue
            }
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator {
                guard url.pathExtension.caseInsensitiveCompare("app") == .orderedSame else {
                    continue
                }
                enumerator.skipDescendants()
                guard let result = applicationResult(at: url) else { continue }
                if let bundleIdentifier = result.bundleIdentifier {
                    if let existing = bestByBundleID[bundleIdentifier],
                       applicationPriority(existing.url.path) <= applicationPriority(url.path) {
                        continue
                    }
                    bestByBundleID[bundleIdentifier] = result
                } else {
                    unbundled[result.url] = result
                }
            }
        }

        return (Array(bestByBundleID.values) + Array(unbundled.values)).sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    nonisolated private static func applicationResult(at url: URL) -> ApplicationSearchResult? {
        let url = url.resolvingSymlinksInPath().standardizedFileURL
        guard let bundle = Bundle(url: url),
              bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL",
              bundle.object(forInfoDictionaryKey: "LSBackgroundOnly") as? Bool != true else {
            return nil
        }
        let displayName = bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String
        let infoDisplayName = bundle.infoDictionary?["CFBundleDisplayName"] as? String
        let localizedName = bundle.localizedInfoDictionary?["CFBundleName"] as? String
        let infoName = bundle.infoDictionary?["CFBundleName"] as? String
        let name = displayName ?? infoDisplayName ?? localizedName ?? infoName
            ?? url.deletingPathExtension().lastPathComponent
        var aliases = [infoDisplayName, localizedName, infoName].compactMap { $0 }
        // Finder's localized title and the bundle's English/Chinese names are
        // aliases for the same app; do not add noisy metadata keywords.
        aliases.append(FileManager.default.displayName(atPath: url.path))
        for language in ["en", "zh-Hans", "zh_CN", "zh-CN"] {
            let stringsURL = url.appendingPathComponent("Contents/Resources/\(language).lproj/InfoPlist.strings")
            guard let info = NSDictionary(contentsOf: stringsURL) as? [String: Any] else { continue }
            aliases.append(contentsOf: ["CFBundleDisplayName", "CFBundleName"].compactMap { info[$0] as? String })
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return ApplicationSearchResult(
            url: url,
            name: name,
            bundleIdentifier: bundle.bundleIdentifier,
            aliases: aliases
        )
    }

    nonisolated private static func applicationPriority(_ path: String) -> Int {
        if path.hasPrefix("/Applications/") { return 0 }
        if path.contains("/Library/CoreServices/") { return 2 }
        if path.hasPrefix("/System/Applications/") { return 3 }
        return 1
    }

}

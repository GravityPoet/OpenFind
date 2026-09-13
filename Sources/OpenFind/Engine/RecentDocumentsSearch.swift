import Foundation

/// Reads the system's per-application recent list, including sfl4 on macOS 27.
/// Decode only Foundation value classes and never launch apps or mount volumes.
enum RecentDocumentsSearch {
    static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.apple.sharedfilelist")

    static func search(_ term: String, application: ApplicationSearchResult? = nil,
                       root: URL = defaultRoot, limit: Int = 50) -> QuickSearchSourceResponse {
        let base: String
        if let application {
            guard let id = application.bundleIdentifier, !id.contains("/"), !id.contains("..") else {
                return .init(message: L("Recent Documents Unavailable"))
            }
            base = "com.apple.LSSharedFileList.ApplicationRecentDocuments/" + id.lowercased()
        } else {
            base = "com.apple.LSSharedFileList.RecentDocuments"
        }
        var seen = Set<URL>()
        for suffix in ["sfl4", "sfl3", "sfl2"] {
            let url = root.appendingPathComponent(base + "." + suffix)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                let urls = try documentURLs(from: BookmarkSearchIndex.readDatabase(url))
                let items = urls.filter { seen.insert($0).inserted }.filter {
                    term.isEmpty || $0.lastPathComponent.localizedStandardContains(term)
                }.map { url in
                    QuickSearchItem(url: url, name: url.lastPathComponent,
                                    location: url.deletingLastPathComponent().path,
                                    action: application.map { .openWithApplication($0.url) } ?? .open)
                }
                return .page(items, limit: limit, message: items.isEmpty ? L("No Recent Documents") : nil)
            } catch { return .init(message: L("Recent Documents Unavailable")) }
        }
        return .init(message: L("No Recent Documents"))
    }

    static func documentURLs(from data: Data) throws -> [URL] {
        let classes: [AnyClass] = [NSDictionary.self, NSArray.self, NSString.self, NSNumber.self, NSData.self, NSDate.self]
        guard let root = try NSKeyedUnarchiver.unarchivedObject(ofClasses: classes, from: data) as? [String: Any],
              let items = root["items"] as? [[String: Any]] else { throw CocoaError(.coderReadCorrupt) }
        return items.compactMap { item in
            guard let bookmark = item["Bookmark"] as? Data else { return nil }
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                    relativeTo: nil, bookmarkDataIsStale: &stale), url.isFileURL,
                  (try? url.checkResourceIsReachable()) == true else { return nil }
            return url
        }
    }
}

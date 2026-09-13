import Foundation

struct QuickBookmarkRecord: Hashable, Sendable {
    let title: String
    let url: URL
    let source: String
    let folder: String
    let candidate: ApplicationSearchResult

    init(title: String, url: URL, source: String, folder: String) {
        self.title = title
        self.url = url
        self.source = source
        self.folder = folder
        candidate = .init(url: url, name: title, bundleIdentifier: nil, aliases: [url.absoluteString, folder])
    }
}

enum BookmarkSearchIndex {
    struct Snapshot: Sendable {
        var records: [QuickBookmarkRecord] = []
        var message: String?
    }

    static func discover(
        safariURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Safari/Bookmarks.plist"),
        chromeRoots: [URL]? = nil
    ) -> Snapshot {
        var snapshot = Snapshot()
        do {
            let data = try readDatabase(safariURL)
            if let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                snapshot.records += safariRecords(from: root)
            }
        } catch {
            let nsError = error as NSError
            if nsError.code != NSFileReadNoSuchFileError && nsError.code != NSFileNoSuchFileError {
                snapshot.message = L("Bookmarks Access Help")
            }
        }
        for root in chromeRoots ?? defaultChromeRoots() {
            do {
                let data = try readDatabase(root.appendingPathComponent("Bookmarks"))
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    snapshot.records += chromeRecords(from: json)
                }
            } catch { snapshot.message = L("Bookmarks Access Help") }
        }
        var seen = Set<URL>()
        snapshot.records = snapshot.records.filter { seen.insert($0.url).inserted }
        return snapshot
    }

    static func search(_ query: String, snapshot: Snapshot, limit: Int) -> QuickSearchSourceResponse {
        let candidates = snapshot.records.map(\.candidate)
        let matched = query.isEmpty ? candidates : ApplicationSearchMatcher.rank(query, in: candidates)
        let records = Dictionary(snapshot.records.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
        let items = matched.compactMap { match -> QuickSearchItem? in
            guard let record = records[match.url] else { return nil }
            return .init(url: record.url, name: record.title,
                         location: [record.source, record.folder, record.url.host ?? ""].filter { !$0.isEmpty }.joined(separator: " · "),
                         kind: .bookmark)
        }
        return .page(items, limit: limit, message: snapshot.message)
    }

    static func safariRecords(from plist: [String: Any], folder: String = "", depth: Int = 0) -> [QuickBookmarkRecord] {
        guard depth < 64 else { return [] }
        var records: [QuickBookmarkRecord] = []
        if let text = plist["URLString"] as? String, let url = WebSearchIndex.directURL(text) {
            let uri = plist["URIDictionary"] as? [String: Any]
            let title = uri?["title"] as? String ?? plist["Title"] as? String ?? url.host ?? text
            records.append(.init(title: title, url: url, source: "Safari", folder: folder))
        }
        let next = plist["Title"] as? String ?? folder
        for child in plist["Children"] as? [[String: Any]] ?? [] {
            records += safariRecords(from: child, folder: next == "com.apple.ReadingList" ? L("Reading List") : next, depth: depth + 1)
        }
        return records
    }

    static func chromeRecords(from json: [String: Any], folder: String = "", depth: Int = 0) -> [QuickBookmarkRecord] {
        guard depth < 64 else { return [] }
        var records: [QuickBookmarkRecord] = []
        if let roots = json["roots"] as? [String: [String: Any]] {
            for key in roots.keys.sorted() {
                records += chromeRecords(from: roots[key] ?? [:], depth: depth + 1)
            }
        }
        if json["type"] as? String == "url", let text = json["url"] as? String,
           let url = WebSearchIndex.directURL(text) {
            records.append(.init(title: json["name"] as? String ?? url.host ?? text,
                                 url: url, source: "Chrome", folder: folder))
        }
        for child in json["children"] as? [[String: Any]] ?? [] {
            records += chromeRecords(from: child, folder: json["name"] as? String ?? folder, depth: depth + 1)
        }
        return records
    }

    static func readDatabase(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let ceiling = 32 * 1024 * 1024
        let data = try handle.read(upToCount: ceiling + 1) ?? Data()
        guard data.count <= ceiling else { throw CocoaError(.fileReadTooLarge) }
        return data
    }

    private static func defaultChromeRoots() -> [URL] {
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Google/Chrome")
        let children = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
        return children.filter { $0.lastPathComponent == "Default" || $0.lastPathComponent.hasPrefix("Profile ") }
            .sorted { $0.path < $1.path }
    }
}

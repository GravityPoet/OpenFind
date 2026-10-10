import Foundation
import OpenFindBrowser

enum BrowserSearchAdapter {
    static func search(_ request: BrowserSearchRequest) async throws -> OpenFindBrowser.Reply {
        let store = SearchIndexStore.shared
        if request.isStatus {
            let stats = await store.stats()
            return OpenFindBrowser.Reply(ok: true, entries: stats.indexedItems,
                full_disk_access: SearchPermissions.hasFullDiskAccess())
        }
        let start = ContinuousClock.now
        var options = await MainActor.run { Preferences.loadOptions() }
        options.target = .name
        options.matchMode = .fuzzy
        options.query = request.query.replacingOccurrences(of: "mtime:", with: "dm:")
            .replacingOccurrences(of: "kind:file", with: "file:")
        if let kind = request.kind { options.query += kind == "dir" ? " folder:" : " file:" }
        if let type = request.type { options.query += " type:" + type }
        if let scope = request.scope, !scope.isEmpty {
            let escaped = scope.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            options.query += " in:\"" + escaped + "\""
        }
        let compiled = try SearchQueryPlan.parse(options.query).compile(options: options)
        let scopes = await MainActor.run { AppDelegate.shared?.viewModel.scopes ?? [SearchScopes.wholeMacURL] }
        var rows: [SearchResult] = []
        if !compiled.shouldRunContentBranch(options: options),
           let snapshot = await SearchEngine.nameResultSnapshot(scopes: scopes, options: options, store: store) {
            let page = await SearchEngine.materializeNamePage(from: snapshot, startingAt: 0, count: request.limit)
            rows = page.results
        } else {
            for await batch in SearchEngine.searchBatches(scopes: scopes, options: options, store: store) {
                try Task.checkCancellation()
                rows.append(contentsOf: batch.prefix(max(0, request.limit - rows.count)))
                if rows.count >= request.limit { break }
            }
        }
        try Task.checkCancellation()
        let hits = rows.enumerated().map { offset, result in
            OpenFindBrowser.Hit(path: result.path, kind: result.isDirectory ? "dir" : "file",
                size: UInt64(max(0, result.size)), mtime: UInt64(max(0, result.modified.timeIntervalSince1970)),
                score: Int64(request.limit - offset))
        }
        let elapsed = start.duration(to: .now).components
        let micros = UInt64(max(0, elapsed.seconds)) * 1_000_000 + UInt64(max(0, elapsed.attoseconds / 1_000_000_000_000))
        return OpenFindBrowser.Reply(ok: true, hits: hits, took_us: micros)
    }
}

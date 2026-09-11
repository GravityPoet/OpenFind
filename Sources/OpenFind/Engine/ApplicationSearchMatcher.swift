import Foundation

enum ApplicationSearchMatcher {
    static func rank(
        _ query: String,
        in candidates: [ApplicationSearchResult],
        usage: SearchUsageSnapshot? = nil
    ) -> [ApplicationSearchResult] {
        let query = ApplicationSearchName.normalize(query)
        guard !query.isEmpty else { return [] }
        let scored: [(score: Int, app: ApplicationSearchResult)] = candidates.compactMap { app in
            guard let score = app.searchNames.compactMap({ score(query, name: $0) }).max() else {
                return nil
            }
            return (score, app)
        }
        return scored.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            let left = usage?.rank(for: lhs.app.url)
            let right = usage?.rank(for: rhs.app.url)
            if left?.openCount != right?.openCount {
                return (left?.openCount ?? 0) > (right?.openCount ?? 0)
            }
            if left?.lastOpened != right?.lastOpened {
                return (left?.lastOpened ?? 0) > (right?.lastOpened ?? 0)
            }
            let order = lhs.app.name.localizedStandardCompare(rhs.app.name)
            return order == .orderedSame
                ? lhs.app.url.path < rhs.app.url.path : order == .orderedAscending
        }.map(\.app)
    }

    private static func score(_ query: String, name: ApplicationSearchName) -> Int? {
        if name.normalized == query { return 2_000 }
        if name.normalized.hasPrefix(query) { return 1_800 }
        if name.initials == query { return 1_700 }
        if name.initials.hasPrefix(query) { return 1_650 }
        if name.words.contains(where: { $0.hasPrefix(query) }) { return 1_600 }
        if !name.pinyin.isEmpty {
            if name.pinyin == query || name.pinyinInitials == query { return 1_550 }
            if name.pinyin.hasPrefix(query) || name.pinyinInitials.hasPrefix(query) { return 1_500 }
        }
        if name.normalized.contains(query) { return 1_300 }
        // Match from a word boundary, as Alfred does; arbitrary one-letter
        // subsequences produce too much noise in an application launcher.
        guard query.count >= 2 else { return nil }
        for index in name.words.indices {
            let suffix = name.words[index...].joined()
            if suffix.first == query.first, isSubsequence(query, of: suffix) { return 1_000 }
        }
        return nil
    }

    private static func isSubsequence(_ query: String, of text: String) -> Bool {
        var index = text.startIndex
        for character in query {
            guard let match = text[index...].firstIndex(of: character) else { return false }
            index = text.index(after: match)
        }
        return true
    }
}

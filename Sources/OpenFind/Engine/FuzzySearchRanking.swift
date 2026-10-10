import Foundation

enum FuzzySearchRanking {
    static func sorted(
        _ nodes: [ResolvedNode], term: String, options: SearchOptions,
        usage: SearchUsageSnapshot?
    ) -> [ResolvedNode] {
        let matcher = FuzzyNameMatcher(term, caseSensitive: options.caseSensitive)
        var scores: [String: UInt8] = [:]
        let scored = nodes.enumerated().map { ordinal, node in
            let rank: UInt8
            if let existing = scores[node.name] { rank = existing }
            else {
                rank = matcher.rank(node.name)
                    ?? matcher.rank(SearchPath.pinyinFirstLetters(from: node.name)) ?? 255
                scores[node.name] = rank
            }
            return (ordinal, node, rank, node.pathDepth, usage?.rank(for: node))
        }
        return scored.sorted(by: { left, right in
            if left.2 != right.2 { return left.2 < right.2 }
            let leftUsage = left.4?.openCount ?? 0, rightUsage = right.4?.openCount ?? 0
            if leftUsage != rightUsage { return leftUsage > rightUsage }
            if left.3 != right.3 { return left.3 < right.3 }
            return left.0 < right.0
        }).map { $0.1 }
    }
}

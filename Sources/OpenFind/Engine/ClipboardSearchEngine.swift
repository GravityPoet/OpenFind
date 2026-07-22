import Foundation

struct ClipboardSearchMatch {
    let score: Int
    let ranges: [Range<String.Index>]
}

enum ClipboardSearchEngine {
    static func match(
        query: String,
        in candidate: String,
        mode: ClipboardSearchMode
    ) -> ClipboardSearchMatch? {
        guard !query.isEmpty else { return ClipboardSearchMatch(score: 0, ranges: []) }
        switch mode {
        case .exact:
            return exact(query: query, candidate: candidate)
        case .fuzzy:
            return fuzzy(query: query, candidate: candidate)
        case .regularExpression:
            return regularExpression(query: query, candidate: candidate)
        case .mixed:
            return exact(query: query, candidate: candidate)
                ?? regularExpression(query: query, candidate: candidate)
                ?? fuzzy(query: query, candidate: candidate)
        }
    }

    private static func exact(
        query: String,
        candidate: String
    ) -> ClipboardSearchMatch? {
        var ranges: [Range<String.Index>] = []
        var remaining = candidate.startIndex..<candidate.endIndex
        while let range = candidate.range(
            of: query,
            options: .caseInsensitive,
            range: remaining
        ) {
            ranges.append(range)
            guard range.upperBound < candidate.endIndex else { break }
            remaining = range.upperBound..<candidate.endIndex
        }
        return ranges.isEmpty ? nil : ClipboardSearchMatch(score: 0, ranges: ranges)
    }

    private static func regularExpression(
        query: String,
        candidate: String
    ) -> ClipboardSearchMatch? {
        guard query.count <= 512,
              let expression = try? NSRegularExpression(pattern: query) else { return nil }
        let nsRange = NSRange(candidate.startIndex..., in: candidate)
        let ranges = expression.matches(in: candidate, range: nsRange).compactMap {
            Range($0.range, in: candidate)
        }
        return ranges.isEmpty ? nil : ClipboardSearchMatch(score: 0, ranges: ranges)
    }

    private static func fuzzy(
        query: String,
        candidate: String
    ) -> ClipboardSearchMatch? {
        let queryCharacters = Array(query.localizedLowercase)
        let candidate = String(candidate.prefix(10_000))
        var queryOffset = 0
        var candidateIndex = candidate.startIndex
        var score = 0
        var previousMatch: String.Index?
        var matchedIndices: [String.Index] = []

        while queryOffset < queryCharacters.count {
            var found: String.Index?
            while candidateIndex < candidate.endIndex {
                if String(candidate[candidateIndex]).localizedLowercase
                    == String(queryCharacters[queryOffset]) {
                    found = candidateIndex
                    break
                }
                candidateIndex = candidate.index(after: candidateIndex)
            }
            guard let match = found else { return nil }
            score += previousMatch.map {
                candidate.distance(from: $0, to: match) == 1 ? 4 : 1
            } ?? (match == candidate.startIndex ? 5 : 2)
            matchedIndices.append(match)
            previousMatch = match
            candidateIndex = candidate.index(after: match)
            queryOffset += 1
        }

        let ranges = matchedIndices.map { index in
            index..<candidate.index(after: index)
        }
        return ClipboardSearchMatch(score: score, ranges: ranges)
    }
}

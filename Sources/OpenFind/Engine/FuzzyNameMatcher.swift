import Foundation

/// Filename-only fuzzy matching: ordered letters, word/camel boundaries, and
/// one non-numeric edit at a word start. Content searches remain literal.
struct FuzzyNameMatcher: Sendable {
    private let query: [UInt8]
    private let caseSensitive: Bool

    init(_ query: String, caseSensitive: Bool = false) {
        self.caseSensitive = caseSensitive
        self.query = Array((caseSensitive ? query : query.lowercased()).utf8)
    }

    func rank(_ name: String) -> UInt8? {
        guard !query.isEmpty else { return nil }
        let original = Array(name.utf8)
        let bytes = caseSensitive ? original : original.map(Self.fold)
        if bytes == query { return 0 }
        let dot = bytes.lastIndex(of: 46).flatMap { $0 > 0 ? $0 : nil }
        if let dot, Array(bytes[..<dot]) == query { return 1 }
        if bytes.starts(with: query) { return 2 }

        var cursor = 0
        var penalty = 0
        var previous: Int?
        var matched = true
        for letter in query {
            guard cursor < bytes.count,
                  let position = bytes[cursor...].firstIndex(of: letter) else {
                matched = false
                break
            }
            if let previous, position > previous + 1 {
                penalty += min(24, position - previous - 1)
            }
            if !Self.isBoundary(original, at: position) { penalty += 4 }
            previous = position
            cursor = position + 1
        }
        if matched { return UInt8(min(159, 3 + penalty + min(12, bytes.count / 16))) }

        // Do not fuzzy-edit Unicode bytes or identifiers containing digits.
        guard query.count >= 5, query.count <= 128,
              query.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }) else { return nil }
        for start in bytes.indices where Self.isBoundary(original, at: start) && bytes[start] == query[0] {
            let remainder = bytes[start...]
            let lower = max(1, query.count - 1), upper = min(remainder.count, query.count + 1)
            guard lower <= upper else { continue }
            for count in lower...upper {
                let word = Array(remainder.prefix(count))
                if Self.oneEdit(word, query) { return UInt8(180 + min(60, start)) }
            }
        }
        return nil
    }

    private static func fold(_ byte: UInt8) -> UInt8 {
        (65...90).contains(byte) ? byte + 32 : byte
    }

    private static func isBoundary(_ bytes: [UInt8], at index: Int) -> Bool {
        guard index > 0 else { return true }
        let before = bytes[index - 1], current = bytes[index]
        let beforeIsLetter = (65...90).contains(before) || (97...122).contains(before)
        let beforeIsDigit = (48...57).contains(before)
        return (!beforeIsLetter && !beforeIsDigit)
            || ((97...122).contains(before) && (65...90).contains(current))
    }

    private static func oneEdit(_ word: [UInt8], _ query: [UInt8]) -> Bool {
        guard abs(word.count - query.count) <= 1,
              word.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }) else { return false }
        var left = 0, right = 0, edits = 0
        while left < word.count && right < query.count {
            if word[left] == query[right] { left += 1; right += 1; continue }
            edits += 1
            guard edits == 1 else { return false }
            if word.count == query.count {
                if left + 1 < word.count, right + 1 < query.count,
                   word[left] == query[right + 1], word[left + 1] == query[right] {
                    left += 2; right += 2
                } else { left += 1; right += 1 }
            } else if word.count > query.count { left += 1 }
            else { right += 1 }
        }
        return edits + (word.count - left) + (query.count - right) == 1
    }
}

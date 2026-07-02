import Foundation

/// Reads a file's text and finds a matching line. Kept separate from
/// `SearchEngine` so traversal and content inspection can evolve independently.
enum ContentMatcher {

    /// Size of the leading window inspected for the binary-file heuristic.
    private static let binarySniffBytes = 8192

    /// Returns the first matching line (trimmed) in `url`, or nil when the file
    /// is oversized, binary, unreadable, or has no match.
    static func firstMatchingLine(in url: URL, matcher: Matcher, maxSize: Int64) -> String? {
        firstMatchingLine(in: url, matchers: [matcher], maxSize: maxSize)
    }

    /// Returns the first line matching all predicates. Multiple predicates are
    /// used for query syntax such as `report content:budget`.
    static func firstMatchingLine(in url: URL, matchers: [Matcher], maxSize: Int64) -> String? {
        guard !matchers.isEmpty else { return nil }
        guard let sizeValue = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              Int64(sizeValue) <= maxSize, sizeValue > 0 else { return nil }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), !data.isEmpty else { return nil }

        // Binary heuristic: a NUL byte in the leading window means "binary", skip.
        if data.prefix(binarySniffBytes).contains(0) { return nil }

        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else { return nil }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let lineText = String(line)
            if matchers.allSatisfy({ $0.matches(lineText) }) {
                return lineText.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }
}

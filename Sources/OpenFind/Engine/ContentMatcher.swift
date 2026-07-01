import Foundation

/// Reads a file's text and finds a matching line. Kept separate from
/// `SearchEngine` so traversal and content inspection can evolve independently.
enum ContentMatcher {

    /// Size of the leading window inspected for the binary-file heuristic.
    private static let binarySniffBytes = 8192

    /// Returns the first matching line (trimmed) in `url`, or nil when the file
    /// is oversized, binary, unreadable, or has no match.
    static func firstMatchingLine(in url: URL, matcher: Matcher, maxSize: Int64) -> String? {
        guard let sizeValue = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              Int64(sizeValue) <= maxSize, sizeValue > 0 else { return nil }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), !data.isEmpty else { return nil }

        // Binary heuristic: a NUL byte in the leading window means "binary", skip.
        if data.prefix(binarySniffBytes).contains(0) { return nil }

        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else { return nil }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if matcher.matches(String(line)) {
                return String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }
}

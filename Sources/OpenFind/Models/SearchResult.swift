import Foundation

/// A single match. Identity is the URL, which de-duplicates naturally.
struct SearchResult: Identifiable, Hashable, Sendable {
    var id: URL { url }
    let url: URL
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int64
    let modified: Date
    /// True when the hit came from content matching, false for a name match.
    let matchedContent: Bool
    /// First matching line (trimmed) for content hits; nil for name hits.
    let contentPreview: String?

    /// The parent directory path, shown as the result's secondary location text.
    var locationPath: String {
        url.deletingLastPathComponent().path(percentEncoded: false)
    }
}

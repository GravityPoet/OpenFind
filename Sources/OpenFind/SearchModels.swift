import Foundation

/// What to match against: file names, file contents, or either.
enum SearchTarget: String, CaseIterable, Sendable, Identifiable, Codable {
    case name
    case content
    case both

    var id: String { rawValue }

    /// Short, human-facing label.
    var label: String {
        switch self {
        case .name: return "Name"
        case .content: return "Contents"
        case .both: return "Name or Contents"
        }
    }
}

/// How the query text is interpreted.
enum MatchMode: String, CaseIterable, Sendable, Identifiable, Codable {
    case substring
    case wholeWord
    case wildcard
    case regex

    var id: String { rawValue }

    var label: String {
        switch self {
        case .substring: return "Contains"
        case .wholeWord: return "Whole Word"
        case .wildcard: return "Wildcard"
        case .regex: return "Regular Expression"
        }
    }
}

/// The full parameter set for one search. A value type, `Sendable`, safe to hand
/// across concurrency boundaries. `Codable` so it can be persisted.
struct SearchOptions: Sendable, Equatable, Codable {
    var query: String = ""
    var target: SearchTarget = .name
    var matchMode: MatchMode = .substring
    var caseSensitive: Bool = false
    var includeHidden: Bool = false
    var includePackages: Bool = false
    /// Skip files larger than this (bytes) during content search. Default 16 MB.
    var maxContentFileSize: Int64 = 16 * 1024 * 1024
}

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
}

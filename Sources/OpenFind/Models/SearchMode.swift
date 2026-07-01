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

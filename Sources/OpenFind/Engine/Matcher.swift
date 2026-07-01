import Foundation

/// Compiles `SearchOptions` into a reusable matching predicate.
///
/// Compiled once, reused across threads. The `substring` mode takes a fast
/// `String.range` path; `wholeWord` / `wildcard` / `regex` compile to an
/// `NSRegularExpression` (thread-safe).
struct Matcher: @unchecked Sendable {

    /// Wraps the non-Sendable compiled product, keeping the Sendable boundary
    /// on `Matcher` itself.
    private struct Box<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }

    private enum Kind {
        case substring(needle: String, caseSensitive: Bool)
        case regex(Box<NSRegularExpression>)
    }

    private let kind: Kind

    /// Throws when the query is empty; callers should intercept before this.
    init(options: SearchOptions) throws {
        let query = options.query
        guard !query.isEmpty else { throw MatcherError.emptyQuery }

        let insensitive: NSRegularExpression.Options = options.caseSensitive ? [] : [.caseInsensitive]

        switch options.matchMode {
        case .substring:
            kind = .substring(needle: query, caseSensitive: options.caseSensitive)

        case .wholeWord:
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: query) + "\\b"
            kind = .regex(Box(try NSRegularExpression(pattern: pattern, options: insensitive)))

        case .wildcard:
            // Escape, then restore wildcards: \* -> .*, \? -> ., anchored to the
            // whole string.
            let escaped = NSRegularExpression.escapedPattern(for: query)
                .replacingOccurrences(of: "\\*", with: ".*")
                .replacingOccurrences(of: "\\?", with: ".")
            kind = .regex(Box(try NSRegularExpression(pattern: "^" + escaped + "$", options: insensitive)))

        case .regex:
            kind = .regex(Box(try NSRegularExpression(pattern: query, options: insensitive)))
        }
    }

    /// Search semantics (not whole-string equality): does `text` contain a match?
    func matches(_ text: String) -> Bool {
        switch kind {
        case let .substring(needle, caseSensitive):
            return text.range(of: needle, options: caseSensitive ? [] : [.caseInsensitive]) != nil
        case let .regex(box):
            let range = NSRange(text.startIndex..., in: text)
            return box.value.firstMatch(in: text, options: [], range: range) != nil
        }
    }
}

enum MatcherError: Error {
    case emptyQuery
}

import Foundation

/// Reads a file's text and finds a matching line. Kept separate from
/// `SearchEngine` so traversal and content inspection can evolve independently.
enum ContentMatcher {

    struct Match {
        let preview: String?
    }

    struct Inspection {
        let extractedText: String?
        let match: Match?
    }

    /// Size of the leading window inspected for the legacy line helper's
    /// binary-file heuristic.
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
              (maxSize == 0 || Int64(sizeValue) <= maxSize), sizeValue > 0 else { return nil }
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

    /// Evaluates the compiled Boolean expression against the complete decoded
    /// file content. This keeps `NOT content:` and mixed OR groups correct;
    /// evaluating independently per line would make negation return false hits.
    static func match(
        in node: ResolvedNode,
        query: CompiledSearchQuery,
        options: SearchOptions
    ) -> Match? {
        inspect(in: node, query: query, options: options).match
    }

    /// Returns extracted text even when the current query does not match. The
    /// caller can then build the persistent trigram index from the same read,
    /// avoiding a second pass over every nonmatching document.
    static func inspect(
        in node: ResolvedNode,
        query: CompiledSearchQuery,
        options: SearchOptions
    ) -> Inspection {
        if let literal = query.streamingContentLiteral(options: options),
           node.node.size >= 16 * 1_024 * 1_024,
           !node.node.isDirectory {
            switch DocumentTextExtractor.streamASCIIPlainTextMatch(
                from: node.url,
                needle: literal,
                caseSensitive: options.caseSensitive
            ) {
            case .match:
                return Inspection(
                    extractedText: nil,
                    match: Match(preview: nil)
                )
            case .noMatch:
                return Inspection(extractedText: nil, match: nil)
            case .unsupported:
                break
            }
        }
        guard let text = DocumentTextExtractor.extract(
            from: node.url,
            maxFileSize: options.maxContentFileSize
        )?.text else { return Inspection(extractedText: nil, match: nil) }
        guard query.matchesContent(text, node: node, options: options) else {
            return Inspection(extractedText: text, match: nil)
        }

        let previewMatchers = query.contentMatchers(for: options)
        guard !previewMatchers.isEmpty else {
            return Inspection(extractedText: text, match: Match(preview: nil))
        }

        let preview = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .first { line in previewMatchers.contains { $0.matches(line) } }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Inspection(extractedText: text, match: Match(preview: preview))
    }

}

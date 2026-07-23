import Foundation

struct ClipboardStructuredQuery: Equatable, Sendable {
    enum Field: String, Sendable {
        case application = "app"
        case type
        case state = "is"
        case collection
    }

    struct Filter: Equatable, Sendable {
        let field: Field
        let value: String
    }

    let text: String
    let filters: [Filter]

    var hasFilters: Bool { !filters.isEmpty }

    static func parse(_ rawQuery: String) -> Self {
        let query = String(rawQuery.prefix(4_096))
        let pattern = #"(?i)(?:^|\s)(app|type|is|collection):(?:"([^"]{1,256})"|([^\s"]{1,256}))"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return Self(text: query.trimmingCharacters(in: .whitespacesAndNewlines), filters: [])
        }
        let range = NSRange(query.startIndex..., in: query)
        let matches = expression.matches(in: query, range: range)
        guard !matches.isEmpty else {
            return Self(text: query.trimmingCharacters(in: .whitespacesAndNewlines), filters: [])
        }

        let mutable = NSMutableString(string: query)
        var filters: [Filter] = []
        for match in matches.reversed() {
            guard let fieldRange = Range(match.range(at: 1), in: query),
                  let field = Field(rawValue: String(query[fieldRange]).localizedLowercase) else {
                continue
            }
            let valueRange = match.range(at: 2).location != NSNotFound
                ? match.range(at: 2) : match.range(at: 3)
            guard let swiftValueRange = Range(valueRange, in: query) else { continue }
            let value = String(query[swiftValueRange])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            filters.append(Filter(field: field, value: value))
            mutable.replaceCharacters(in: match.range, with: " ")
        }

        let text = (mutable as String)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return Self(text: text, filters: filters.reversed())
    }

    static func token(field: Field, value: String) -> String? {
        let clean = value
            .filter { !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }
            .replacingOccurrences(of: "\"", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        return clean.contains(where: \.isWhitespace)
            ? #"\#(field.rawValue):"\#(clean)""#
            : "\(field.rawValue):\(clean)"
    }

    func matches(_ entry: ClipboardEntry) -> Bool {
        filters.allSatisfy { filter in
            switch filter.field {
            case .application:
                return [
                    entry.sourceApplicationName,
                    entry.sourceBundleIdentifier,
                ].compactMap { $0 }.contains {
                    $0.localizedCaseInsensitiveContains(filter.value)
                }
            case .type:
                return matchesType(filter.value, entry: entry)
            case .state:
                return matchesState(filter.value, entry: entry)
            case .collection:
                return entry.snippetCollection?
                    .localizedCaseInsensitiveContains(filter.value) == true
            }
        }
    }

    private func matchesType(_ value: String, entry: ClipboardEntry) -> Bool {
        switch value.localizedLowercase {
        case "text", "文本":
            return entry.kind == .text
        case "rich", "richtext", "rich-text", "富文本":
            return entry.kind == .richText
        case "url", "link", "链接", "网址":
            return entry.kind == .url
        case "file", "files", "文件":
            return entry.kind == .file
        case "image", "images", "图片", "图像":
            return entry.kind == .image
        case "other", "其他":
            return entry.kind == .other
        default:
            return false
        }
    }

    private func matchesState(_ value: String, entry: ClipboardEntry) -> Bool {
        switch value.localizedLowercase {
        case "pinned", "saved", "reusable", "置顶", "已保存", "复用":
            return entry.isPinned
        case "unpinned", "未置顶":
            return !entry.isPinned
        case "snippet", "片段":
            return entry.snippetKeyword != nil || entry.snippetExpansionEnabled != nil
        default:
            return false
        }
    }
}

import Foundation

struct ClipboardSnippetArchive: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int
    var exportedAt: Date
    var snippets: [ClipboardSnippetRecord]

    init(
        version: Int = currentVersion,
        exportedAt: Date = Date(),
        snippets: [ClipboardSnippetRecord]
    ) {
        self.version = version
        self.exportedAt = exportedAt
        self.snippets = snippets
    }
}

struct ClipboardSnippetRecord: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var content: String
    var keyword: String?
    var collection: String?
    var expandsAutomatically: Bool
}

enum ClipboardSnippetError: Error, Equatable, LocalizedError {
    case unsupportedArchiveVersion
    case archiveTooLarge
    case tooManySnippets
    case duplicateIdentifiers
    case invalidName
    case invalidContent
    case invalidKeyword
    case duplicateKeyword
    case invalidCollection
    case textOnly

    var errorDescription: String? {
        switch self {
        case .unsupportedArchiveVersion:
            L("Snippet Archive Version Unsupported")
        case .archiveTooLarge:
            L("Snippet Archive Too Large")
        case .tooManySnippets:
            L("Snippet Archive Has Too Many Items")
        case .duplicateIdentifiers:
            L("Snippet Archive Duplicate IDs")
        case .invalidName:
            L("Snippet Name Invalid")
        case .invalidContent:
            L("Snippet Content Invalid")
        case .invalidKeyword:
            L("Snippet Keyword Invalid")
        case .duplicateKeyword:
            L("Snippet Keyword Already Used")
        case .invalidCollection:
            L("Snippet Collection Invalid")
        case .textOnly:
            L("Snippet Text Only")
        }
    }
}

struct RenderedClipboardSnippet: Equatable, Sendable {
    let text: String
    let cursorOffsetFromEnd: Int
}

enum ClipboardSnippetRenderer {
    static func render(
        _ template: String,
        now: Date = Date(),
        locale: Locale = .current,
        timeZone: TimeZone = .current,
        clipboardText: () -> String? = { nil },
        uuid: () -> UUID = UUID.init
    ) -> RenderedClipboardSnippet {
        let pattern = #"\{\{([^{}]{1,128})\}\}|\{([^{}]{1,128})\}"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return RenderedClipboardSnippet(text: template, cursorOffsetFromEnd: 0)
        }
        let nsTemplate = template as NSString
        let matches = expression.matches(
            in: template,
            range: NSRange(location: 0, length: nsTemplate.length)
        )
        var rendered = template
        let cursorMarker = "\u{F8FF}OPENFIND_CURSOR_\(UUID().uuidString)\u{F8FF}"
        var insertedCursor = false
        var resolvedClipboard: String?

        for match in matches.reversed() {
            let tokenRange = match.range(at: 1).location != NSNotFound
                ? match.range(at: 1) : match.range(at: 2)
            guard let fullRange = Range(match.range, in: rendered),
                  tokenRange.location != NSNotFound else { continue }
            let token = nsTemplate.substring(with: tokenRange)
            let replacement: String?
            switch token.lowercased() {
            case "date":
                replacement = formatted(
                    now,
                    dateStyle: .medium,
                    timeStyle: .none,
                    locale: locale,
                    timeZone: timeZone
                )
            case "time":
                replacement = formatted(
                    now,
                    dateStyle: .none,
                    timeStyle: .short,
                    locale: locale,
                    timeZone: timeZone
                )
            case "datetime":
                replacement = formatted(
                    now,
                    dateStyle: .medium,
                    timeStyle: .short,
                    locale: locale,
                    timeZone: timeZone
                )
            case "clipboard":
                if resolvedClipboard == nil { resolvedClipboard = clipboardText() ?? "" }
                replacement = resolvedClipboard
            case "uuid":
                replacement = uuid().uuidString.lowercased()
            case "cursor":
                if insertedCursor {
                    replacement = ""
                } else {
                    insertedCursor = true
                    replacement = cursorMarker
                }
            default:
                replacement = customDateReplacement(
                    token: token,
                    now: now,
                    locale: locale,
                    timeZone: timeZone
                )
            }
            if let replacement {
                rendered.replaceSubrange(fullRange, with: replacement)
            }
        }

        guard let markerRange = rendered.range(of: cursorMarker) else {
            return RenderedClipboardSnippet(text: rendered, cursorOffsetFromEnd: 0)
        }
        let offset = rendered[markerRange.upperBound...].count
        rendered.removeSubrange(markerRange)
        return RenderedClipboardSnippet(text: rendered, cursorOffsetFromEnd: offset)
    }

    private static func customDateReplacement(
        token: String,
        now: Date,
        locale: Locale,
        timeZone: TimeZone
    ) -> String? {
        let parts = token.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              ["date", "time", "datetime"].contains(parts[0].lowercased()),
              !parts[1].isEmpty,
              parts[1].count <= 64 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = String(parts[1])
        return formatter.string(from: now)
    }

    private static func formatted(
        _ date: Date,
        dateStyle: DateFormatter.Style,
        timeStyle: DateFormatter.Style,
        locale: Locale,
        timeZone: TimeZone
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = dateStyle
        formatter.timeStyle = timeStyle
        return formatter.string(from: date)
    }
}

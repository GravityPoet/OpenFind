import Foundation

enum QuickSearchMode: String, CaseIterable, Sendable {
    case combined, applications, settings, open, find, content, tags, path, bookmarks, contacts, recent, calculator, dictionary, system, web, terminal

    var prefix: String {
        switch self {
        case .combined: return ""
        case .applications: return "app "
        case .settings: return "settings "
        case .path: return "~/"
        case .bookmarks: return "bm "
        case .terminal: return QuickTerminalPrefix.load() + " "
        default: return rawValue == "content" ? "in " : rawValue + " "
        }
    }

    var titleKey: String {
        switch self {
        case .combined: return "Quick Search"
        case .applications: return "Applications"
        case .settings: return "System Settings"
        case .open: return "Open"
        case .find: return "Reveal in Finder"
        case .content: return "Search File Contents"
        case .tags: return "Search Finder Tags"
        case .path: return "Browse Folders"
        case .bookmarks: return "Bookmarks"
        case .contacts: return "Contacts"
        case .recent: return "Recent Documents"
        case .calculator: return "Calculator"
        case .dictionary: return "Dictionary"
        case .system: return "System Commands"
        case .web: return "Web Search"
        case .terminal: return "Run in Terminal"
        }
    }
}

/// Only explicit verbs change modes. Existing colon-based full-search syntax
/// remains intact, and a leading space opts into file search, as in Alfred.
struct QuickSearchCommand: Equatable, Sendable {
    let mode: QuickSearchMode
    let term: String

    static func parse(_ rawQuery: String, terminalPrefix: String = QuickTerminalPrefix.load()) -> Self {
        // Preserve command bytes until validation, including boundary newlines.
        let prefix = QuickTerminalPrefix.normalized(terminalPrefix) ?? QuickTerminalPrefix.defaultValue
        if rawQuery.hasPrefix(prefix + " ") || rawQuery.hasPrefix(prefix.uppercased() + " ") {
            return .init(mode: .terminal, term: String(rawQuery.dropFirst(2)))
        }
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if rawQuery.hasPrefix(" ") { return .init(mode: .open, term: query) }
        if query.hasPrefix("/") || query.hasPrefix("~") { return .init(mode: .path, term: query) }
        if WebSearchIndex.directURL(query) != nil { return .init(mode: .web, term: query) }
        let parts = query.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        // "Contacts", "Dictionary", and "Settings" can be application names.
        // A separating space opts into the corresponding command.
        guard parts.count > 1 || rawQuery.last?.isWhitespace == true else {
            return .init(mode: .combined, term: query)
        }
        let keyword = parts.first.map(String.init)?.lowercased() ?? ""
        let term = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let mode: QuickSearchMode
        switch keyword {
        case "app", "apps", "应用": mode = .applications
        case "settings", "设置": mode = .settings
        case "open": mode = .open
        case "find": mode = .find
        case "in": mode = .content
        case "tags": mode = .tags
        case "bm", "bookmarks", "书签": mode = .bookmarks
        case "contacts", "contact", "联系人": mode = .contacts
        case "recent", "最近": mode = .recent
        case "calc", "calculator", "计算": mode = .calculator
        case "define", "dict", "dictionary", "释义", "字典": mode = .dictionary
        case "system", "系统": mode = .system
        case "web", "网页": mode = .web
        default: return .init(mode: .combined, term: query)
        }
        return .init(mode: mode, term: term)
    }

    var fullSearchQuery: String {
        switch mode {
        case .content: return term.isEmpty ? "" : "content:" + Self.quoted(term)
        case .tags: return term.isEmpty ? "" : "tag:" + Self.quoted(term)
        case .path:
            let path = (term as NSString).expandingTildeInPath
            let name = (path as NSString).lastPathComponent
            if name.contains("*") || name.contains("?") {
                return "parent:" + Self.quoted((path as NSString).deletingLastPathComponent) + " " + name
            }
            return "path:" + Self.quoted(path)
        default: return term
        }
    }

    static func quoted(_ term: String) -> String {
        "\"" + term.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    var hintKey: String {
        switch mode {
        case .combined, .applications, .settings: return "Quick Search Help"
        case .open: return "Quick Search Open Hint"
        case .find: return "Quick Search Find Hint"
        case .content: return "Quick Search Content Hint"
        case .tags: return "Quick Search Tags Hint"
        case .path: return "Quick Search Path Hint"
        case .bookmarks: return "Quick Search Bookmarks Hint"
        case .contacts: return "Quick Search Contacts Hint"
        case .recent: return "Quick Search Recent Hint"
        case .calculator: return "Quick Search Calculator Hint"
        case .dictionary: return "Quick Search Dictionary Hint"
        case .system: return "Quick Search System Hint"
        case .web: return "Quick Search Web Hint"
        case .terminal: return "Quick Search Terminal Hint"
        }
    }

    var localizedHint: String {
        mode == .terminal ? String(format: LD(hintKey), QuickTerminalPrefix.load()) : LD(hintKey)
    }
}

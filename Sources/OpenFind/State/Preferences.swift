import Foundation

/// Lightweight persistence for durable user settings, backed by `UserDefaults`.
/// The transient search query is intentionally never persisted.
enum Preferences {
    // UserDefaults is thread-safe; the annotation documents that guarantee.
    nonisolated(unsafe) private static let defaults = UserDefaults.standard
    private static let recentLimit = 10

    private enum Key {
        static let target = "search.target"
        static let matchMode = "search.matchMode"
        static let caseSensitive = "search.caseSensitive"
        static let includeHidden = "search.includeHidden"
        static let includePackages = "search.includePackages"
        static let recentSearches = "search.recent"
    }

    /// Loads durable option fields (everything except the query).
    static func loadOptions() -> SearchOptions {
        var options = SearchOptions()
        if let raw = defaults.string(forKey: Key.target), let value = SearchTarget(rawValue: raw) {
            options.target = value
        }
        if let raw = defaults.string(forKey: Key.matchMode), let value = MatchMode(rawValue: raw) {
            options.matchMode = value
        }
        options.caseSensitive = defaults.bool(forKey: Key.caseSensitive)
        options.includeHidden = defaults.bool(forKey: Key.includeHidden)
        options.includePackages = defaults.bool(forKey: Key.includePackages)
        return options
    }

    /// Saves durable option fields. The query is deliberately excluded.
    static func saveOptions(_ options: SearchOptions) {
        defaults.set(options.target.rawValue, forKey: Key.target)
        defaults.set(options.matchMode.rawValue, forKey: Key.matchMode)
        defaults.set(options.caseSensitive, forKey: Key.caseSensitive)
        defaults.set(options.includeHidden, forKey: Key.includeHidden)
        defaults.set(options.includePackages, forKey: Key.includePackages)
    }

    static var recentSearches: [String] {
        get { defaults.stringArray(forKey: Key.recentSearches) ?? [] }
        set { defaults.set(Array(newValue.prefix(recentLimit)), forKey: Key.recentSearches) }
    }

    /// Inserts a query at the front, de-duplicated case-insensitively.
    static func addRecentSearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var list = recentSearches.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
        list.insert(trimmed, at: 0)
        recentSearches = list
    }

    static func clearRecentSearches() {
        recentSearches = []
    }
}

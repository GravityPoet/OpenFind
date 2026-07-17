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
        static let comprehensiveResultsDefault = "search.comprehensiveResultsDefaultV1"
        static let deepIndex = "search.deepIndex"
        static let comprehensiveIndexDefault = "search.comprehensiveIndexDefaultV1"
        static let maxContentFileSize = "search.maxContentFileSize"
        static let comprehensiveContentSizeDefault = "search.comprehensiveContentSizeDefaultV2"
        static let maxContentIndexBytes = "search.maxContentIndexBytes"
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
        options.includeHidden = defaults.object(forKey: Key.includeHidden) as? Bool ?? true
        if defaults.object(forKey: Key.comprehensiveResultsDefault) == nil {
            options.includePackages = true
            defaults.set(true, forKey: Key.includePackages)
            defaults.set(true, forKey: Key.comprehensiveResultsDefault)
        } else {
            options.includePackages = defaults.object(forKey: Key.includePackages) as? Bool ?? true
        }
        if defaults.object(forKey: Key.comprehensiveIndexDefault) == nil {
            options.deepIndex = true
            defaults.set(true, forKey: Key.deepIndex)
            defaults.set(true, forKey: Key.comprehensiveIndexDefault)
        } else {
            options.deepIndex = defaults.object(forKey: Key.deepIndex) as? Bool ?? true
        }
        let storedContentSize = defaults.object(forKey: Key.maxContentFileSize) as? NSNumber
        if defaults.object(forKey: Key.comprehensiveContentSizeDefault) == nil {
            let oldDefault: Int64 = 16 * 1_024 * 1_024
            if storedContentSize == nil || storedContentSize?.int64Value == oldDefault {
                defaults.set(options.maxContentFileSize, forKey: Key.maxContentFileSize)
            } else if let storedContentSize {
                options.maxContentFileSize = storedContentSize.int64Value
            }
            defaults.set(true, forKey: Key.comprehensiveContentSizeDefault)
        } else if let storedContentSize {
            options.maxContentFileSize = storedContentSize.int64Value
        }
        if let storedIndexSize = defaults.object(forKey: Key.maxContentIndexBytes) as? NSNumber {
            options.maxContentIndexBytes = max(0, storedIndexSize.int64Value)
        }
        options.useFrequencyRanking = SearchUsageStore.shared.isEnabled
        return options
    }

    /// Saves durable option fields. The query is deliberately excluded.
    static func saveOptions(_ options: SearchOptions) {
        defaults.set(options.target.rawValue, forKey: Key.target)
        defaults.set(options.matchMode.rawValue, forKey: Key.matchMode)
        defaults.set(options.caseSensitive, forKey: Key.caseSensitive)
        defaults.set(options.includeHidden, forKey: Key.includeHidden)
        defaults.set(options.includePackages, forKey: Key.includePackages)
        defaults.set(options.deepIndex, forKey: Key.deepIndex)
        defaults.set(options.maxContentFileSize, forKey: Key.maxContentFileSize)
        defaults.set(options.maxContentIndexBytes, forKey: Key.maxContentIndexBytes)
        SearchUsageStore.shared.isEnabled = options.useFrequencyRanking
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

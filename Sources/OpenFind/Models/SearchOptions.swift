import Foundation

/// The full parameter set for one search. A value type, `Sendable`, safe to hand
/// across concurrency boundaries. `Codable` so it can be persisted.
struct SearchOptions: Sendable, Equatable, Codable {
    var query: String = ""
    var target: SearchTarget = .name
    var matchMode: MatchMode = .substring
    var caseSensitive: Bool = false
    var includeHidden: Bool = true
    var includePackages: Bool = true
    /// Comprehensive indexing is the default. Turning this off opts into a
    /// lighter index that excludes cache, log, and temporary noise.
    var deepIndex: Bool = true
    /// Device-local successful-open history may reorder equal-relevance hits.
    /// It never removes candidates or outranks a better semantic match.
    var useFrequencyRanking: Bool = true
    /// Skip files larger than this (bytes) during content search. A value of
    /// zero removes the size ceiling; content workers still share a bounded
    /// memory budget so large-file searches do not multiply peak memory use.
    var maxContentFileSize: Int64 = 100 * 1024 * 1024
    /// Maximum on-disk size of the rebuildable content acceleration database.
    /// A value of zero removes the cache ceiling. Reaching this budget never
    /// changes the searchable scope: uncached files stay on the authoritative
    /// raw-file scan path.
    var maxContentIndexBytes: Int64 = 4 * 1024 * 1024 * 1024

    func allowsContentFileSize(_ size: Int64) -> Bool {
        maxContentFileSize == 0 || size <= maxContentFileSize
    }
}

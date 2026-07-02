import Foundation

/// The full parameter set for one search. A value type, `Sendable`, safe to hand
/// across concurrency boundaries. `Codable` so it can be persisted.
struct SearchOptions: Sendable, Equatable, Codable {
    var query: String = ""
    var target: SearchTarget = .name
    var matchMode: MatchMode = .substring
    var caseSensitive: Bool = false
    var includeHidden: Bool = false
    var includePackages: Bool = false
    /// Index everything: drop the built-in noise ignore list (caches, logs,
    /// /Volumes, CloudStorage). Slower first build, zero blind spots.
    var deepIndex: Bool = false
    /// Skip files larger than this (bytes) during content search. Default 16 MB.
    var maxContentFileSize: Int64 = 16 * 1024 * 1024
}

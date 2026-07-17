import Foundation

struct SearchUsageRank: Sendable, Equatable {
    let openCount: Int
    let lastOpened: Double
}

struct SearchUsageSnapshot: Sendable {
    private let ranksByPath: [String: SearchUsageRank]
    private let candidateNames: Set<String>

    init(ranksByPath: [String: SearchUsageRank]) {
        self.ranksByPath = ranksByPath
        candidateNames = Set(ranksByPath.keys.map { ($0 as NSString).lastPathComponent })
    }

    var isEmpty: Bool { ranksByPath.isEmpty }

    /// Avoids resolving a deferred full path for virtually every result. Only
    /// names shared by one of the small number of local history records need a
    /// path lookup and exact-path verification.
    func rank(for node: ResolvedNode) -> SearchUsageRank? {
        guard candidateNames.contains(node.name) else { return nil }
        return ranksByPath[SearchPath.canonicalIndexedPath(node.path)]
    }
}

/// A bounded, device-local history used only as a relevance tie breaker.
/// Nothing here filters a candidate or leaves the Mac through OpenFind.
final class SearchUsageStore: @unchecked Sendable {
    static let shared = SearchUsageStore(defaults: .standard)

    private struct Record: Codable {
        let path: String
        var openCount: Int
        var lastOpened: Double
    }

    private static let enabledKey = "search.useFrequencyRanking"
    private static let recordsKey = "search.localUsageRecordsV1"
    private static let defaultMaximumRecords = 500

    private let defaults: UserDefaults
    private let maximumRecords: Int
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var loadedRecords: [String: Record]?

    init(
        defaults: UserDefaults,
        maximumRecords: Int = defaultMaximumRecords,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.maximumRecords = max(1, maximumRecords)
        self.now = now
    }

    var isEnabled: Bool {
        get { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.enabledKey) }
    }

    func recordSuccessfulOpen(_ url: URL) {
        guard isEnabled else { return }
        let path = SearchPath.canonicalAliasPath(url.path(percentEncoded: false))
        guard !path.isEmpty else { return }

        lock.lock()
        var records = recordsLocked()
        let timestamp = now().timeIntervalSinceReferenceDate
        if var record = records[path] {
            if record.openCount < Int.max {
                record.openCount += 1
            }
            record.lastOpened = timestamp
            records[path] = record
        } else {
            records[path] = Record(path: path, openCount: 1, lastOpened: timestamp)
        }
        if records.count > maximumRecords {
            let overflow = records.count - maximumRecords
            let evicted = records.values.sorted {
                if $0.lastOpened != $1.lastOpened { return $0.lastOpened < $1.lastOpened }
                return $0.openCount < $1.openCount
            }.prefix(overflow)
            for record in evicted { records.removeValue(forKey: record.path) }
        }
        loadedRecords = records
        persistLocked(records)
        lock.unlock()
    }

    func snapshot() -> SearchUsageSnapshot? {
        guard isEnabled else { return nil }
        lock.lock()
        let records = recordsLocked()
        lock.unlock()
        guard !records.isEmpty else { return nil }
        return SearchUsageSnapshot(ranksByPath: records.mapValues {
            SearchUsageRank(openCount: $0.openCount, lastOpened: $0.lastOpened)
        })
    }

    func clear() {
        lock.lock()
        loadedRecords = [:]
        defaults.removeObject(forKey: Self.recordsKey)
        lock.unlock()
    }

    var recordCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordsLocked().count
    }

    private func recordsLocked() -> [String: Record] {
        if let loadedRecords { return loadedRecords }
        guard let data = defaults.data(forKey: Self.recordsKey),
              let decoded = try? PropertyListDecoder().decode([Record].self, from: data) else {
            loadedRecords = [:]
            return [:]
        }
        var records: [String: Record] = [:]
        for record in decoded where !record.path.isEmpty && record.openCount > 0 {
            let canonicalPath = SearchPath.canonicalAliasPath(record.path)
            guard !canonicalPath.isEmpty else { continue }
            var canonicalRecord = record
            canonicalRecord = Record(
                path: canonicalPath,
                openCount: record.openCount,
                lastOpened: record.lastOpened
            )
            if let existing = records[canonicalPath] {
                if canonicalRecord.lastOpened > existing.lastOpened
                    || (canonicalRecord.lastOpened == existing.lastOpened
                        && canonicalRecord.openCount > existing.openCount) {
                    records[canonicalPath] = canonicalRecord
                }
            } else {
                records[canonicalPath] = canonicalRecord
            }
            if records.count >= maximumRecords { break }
        }
        loadedRecords = records
        return records
    }

    private func persistLocked(_ records: [String: Record]) {
        let ordered = records.values.sorted {
            if $0.lastOpened != $1.lastOpened { return $0.lastOpened > $1.lastOpened }
            return $0.path < $1.path
        }
        guard let data = try? PropertyListEncoder().encode(ordered) else { return }
        defaults.set(data, forKey: Self.recordsKey)
    }
}

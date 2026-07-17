import Foundation
import Testing
@testable import OpenFind

@Suite("Local Search Usage Tests", .serialized)
struct SearchUsageStoreTests {
    private struct PersistedRecord: Codable {
        let path: String
        let openCount: Int
        let lastOpened: Double
    }

    private func defaults() throws -> (UserDefaults, String) {
        let suite = "OpenFindUsageTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    private func node(name: String, path: String) -> ResolvedNode {
        ResolvedNode(
            node: IndexedFileNode(
                name: name,
                parentIndex: -1,
                isDirectory: false,
                size: 0,
                modifiedTime: 0,
                creationTime: 0,
                isHiddenScope: false,
                isPackageDescendant: false
            ),
            path: path
        )
    }

    @Test func historyIsBoundedPersistentDisableableAndClearable() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SearchUsageStore(
            defaults: defaults,
            maximumRecords: 2,
            now: { Date(timeIntervalSinceReferenceDate: 700_000_000) }
        )

        store.recordSuccessfulOpen(URL(fileURLWithPath: "/tmp/one.txt"))
        store.recordSuccessfulOpen(URL(fileURLWithPath: "/tmp/two.txt"))
        store.recordSuccessfulOpen(URL(fileURLWithPath: "/tmp/three.txt"))
        #expect(store.recordCount == 2)

        let reloaded = SearchUsageStore(defaults: defaults, maximumRecords: 2)
        #expect(reloaded.recordCount == 2)
        reloaded.isEnabled = false
        reloaded.recordSuccessfulOpen(URL(fileURLWithPath: "/tmp/disabled.txt"))
        #expect(reloaded.recordCount == 2)
        #expect(reloaded.snapshot() == nil)

        reloaded.clear()
        #expect(reloaded.recordCount == 0)
    }

    @Test func usageBreaksOnlySemanticTiesAndNeverChangesMembership() throws {
        var options = SearchOptions(query: "report")
        options.useFrequencyRanking = true
        let query = try SearchQueryPlan.parse(options.query).compile(options: options)
        let exact = node(name: "report", path: "/deep/report")
        let stem = node(name: "report.txt", path: "/deeper/report.txt")
        let unusedTie = node(name: "alpha-report.txt", path: "/alpha-report.txt")
        let usedTie = node(name: "beta-report.txt", path: "/very/deep/beta-report.txt")
        let input = [unusedTie, stem, usedTie, exact]
        let snapshot = SearchUsageSnapshot(ranksByPath: [
            usedTie.path: SearchUsageRank(openCount: 20, lastOpened: 700_000_000),
            stem.path: SearchUsageRank(openCount: 100, lastOpened: 700_000_001),
        ])

        let ranked = SearchRanking.sortedByRelevance(
            input,
            query: query,
            options: options,
            usageSnapshot: snapshot
        )

        #expect(ranked.map(\.path) == [
            exact.path,
            stem.path,
            usedTie.path,
            unusedTie.path,
        ])
        #expect(Set(ranked.map(\.path)) == Set(input.map(\.path)))
    }

    @Test func malformedDuplicateHistoryLoadsWithoutCrashing() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let path = "/tmp/openfind-duplicate.txt"
        let data = try PropertyListEncoder().encode([
            PersistedRecord(path: path, openCount: 2, lastOpened: 10),
            PersistedRecord(path: path, openCount: 7, lastOpened: 20),
        ])
        defaults.set(data, forKey: "search.localUsageRecordsV1")

        let store = SearchUsageStore(defaults: defaults, maximumRecords: 5)
        let snapshot = try #require(store.snapshot())
        let rank = try #require(snapshot.rank(for: node(
            name: "openfind-duplicate.txt",
            path: path
        )))

        #expect(store.recordCount == 1)
        #expect(rank == SearchUsageRank(openCount: 7, lastOpened: 20))
    }

    @Test func pinyinEligibilityIsCompiledWithoutARegexHotPath() throws {
        var options = SearchOptions(query: "zw2026")
        let initials = try SearchQueryPlan.parse(options.query).compile(options: options)
        #expect(initials.matchesPinyin)

        options.query = "中w"
        let han = try SearchQueryPlan.parse(options.query).compile(options: options)
        #expect(!han.matchesPinyin)

        options.query = "z-w"
        let punctuation = try SearchQueryPlan.parse(options.query).compile(options: options)
        #expect(!punctuation.matchesPinyin)
    }
}

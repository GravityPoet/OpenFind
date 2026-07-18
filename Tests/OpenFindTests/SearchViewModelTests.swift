import Foundation
import Testing
@testable import OpenFind

private final class BuildInvocationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func record() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

@Suite("Search View Model Tests", .serialized)
struct SearchViewModelTests {
    @MainActor
    private func makeViewModel(
        resultPageSize: Int = 2_000,
        indexStore: SearchIndexStore? = nil,
        automaticSearchQuietPeriod: Duration = .seconds(3)
    ) -> SearchViewModel {
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenFind-ViewModelCache-\(UUID().uuidString).bin")
        let viewModel = SearchViewModel(
            indexStore: indexStore ?? SearchIndexStore(persistenceURL: cacheURL),
            startIndexing: false,
            resultPageSize: resultPageSize,
            automaticSearchQuietPeriod: automaticSearchQuietPeriod
        )
        // Tests that trigger an automatic refresh must never inherit the
        // persisted whole-Mac scope from the production preferences.
        viewModel.scopes = [FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenFind-ViewModelScope-\(UUID().uuidString)", isDirectory: true)]
        return viewModel
    }

    @MainActor
    @Test func automaticReSearchPreservesVisibleResultsAndElapsedTime() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenFind-SearchViewModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let matchURL = root.appendingPathComponent("needle.txt")
        try Data("needle".utf8).write(to: matchURL)

        let viewModel = makeViewModel()
        viewModel.scopes = [root]
        viewModel.options = SearchOptions(query: "needle")
        viewModel.startSearch()

        for _ in 0..<200 where viewModel.isSearching {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!viewModel.isSearching)

        viewModel.results = [SearchResult(
            name: matchURL.lastPathComponent,
            path: matchURL.path(percentEncoded: false),
            isDirectory: false,
            size: 6,
            modified: .now,
            created: .now,
            matchedContent: false,
            contentPreview: nil
        )]
        viewModel.elapsed = 0.25

        viewModel.startSearch(recordRecent: false, clearResults: false)

        #expect(viewModel.resultCount == 1)
        #expect(viewModel.elapsed >= 0.25)
        viewModel.cancel()
    }

    @MainActor
    @Test func automaticReSearchStreamsWhenNoVisibleSnapshotExists() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenFind-AutoStreamTests-\(UUID().uuidString)", isDirectory: true)
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenFind-AutoStreamCache-\(UUID().uuidString).bin")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: cacheURL)
        }
        try Data().write(to: root.appendingPathComponent("live-result.txt"))

        let store = SearchIndexStore(persistenceURL: cacheURL)
        _ = await store.refresh(scopes: [root], deepIndex: true, hasFullDiskAccess: true)
        let viewModel = makeViewModel(indexStore: store)
        viewModel.scopes = [root]
        viewModel.options = SearchOptions(query: "live-result")

        var growingStats = SearchIndexStats()
        growingStats.indexedFiles = 1
        growingStats.isIndexing = true
        viewModel.handleStatsTick(growingStats, fullDiskAccess: true)

        #expect(viewModel.isSearching)
        #expect(!viewModel.isRefreshingSearchResults)
        for _ in 0..<200 where viewModel.isSearching {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(viewModel.totalResultCount == 1)
        #expect(viewModel.resultCount == 1)
    }

    @MainActor
    @Test func launchTimeSearchDoesNotDeadlockIndexRecovery() async throws {
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenFind-LaunchSearchCache-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let store = SearchIndexStore(persistenceURL: cacheURL, buildOperation: { _ in
            SearchWorkCoordinator.shared.waitForSearchesToFinish()
            return SearchIndexBuildResult(nodes: [], unresolvedPaths: [])
        })
        let viewModel = makeViewModel(indexStore: store)
        viewModel.options = SearchOptions(query: "launch-query")
        viewModel.startSearch()

        for _ in 0..<200 where viewModel.isSearching {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(!viewModel.isSearching)
        viewModel.cancel()
    }

    @MainActor
    @Test func clearingQueryResetsElapsedAndPaginationState() {
        let viewModel = makeViewModel()
        viewModel.options.query = "needle"
        viewModel.elapsed = 1.25

        viewModel.options.query = ""
        viewModel.scheduleSearch(delay: .zero)

        #expect(viewModel.elapsed == 0)
        #expect(viewModel.results.isEmpty)
        #expect(viewModel.totalResultCount == 0)
        #expect(!viewModel.hasMoreResults)
    }

    @MainActor
    @Test func eventFilteringRunsOnlyWhileEventViewIsVisible() {
        let viewModel = makeViewModel()
        viewModel.eventEntries = [
            FileSystemEventLogEntry(
                id: 1,
                receivedAt: .now,
                eventID: 1,
                flags: UInt32(kFSEventStreamEventFlagItemCreated),
                path: "/tmp/needle.txt"
            ),
            FileSystemEventLogEntry(
                id: 2,
                receivedAt: .now,
                eventID: 2,
                flags: UInt32(kFSEventStreamEventFlagItemRemoved),
                path: "/tmp/other.txt"
            ),
        ]

        #expect(viewModel.filteredEventEntries.isEmpty)
        viewModel.displayMode = .events
        viewModel.eventEntries = viewModel.eventEntries
        #expect(viewModel.filteredEventEntries.count == 2)
        viewModel.options.query = "needle"
        #expect(viewModel.filteredEventEntries.map(\.name) == ["needle.txt"])
        viewModel.options.query = "removed"
        #expect(viewModel.filteredEventEntries.map(\.name) == ["other.txt"])
        viewModel.options.query = ""
        #expect(viewModel.filteredEventEntries.count == 2)
    }

    @Test func elapsedDisplayUsesMillisecondsBelowOneSecondAndTenthsAfterward() {
        #expect(SearchElapsedDisplay.value(for: 0.842) == .milliseconds(842))
        #expect(SearchElapsedDisplay.value(for: 0.9999) == .milliseconds(999))
        #expect(SearchElapsedDisplay.value(for: 1.0) == .secondsTenths(10))
        #expect(SearchElapsedDisplay.value(for: 2.03) == .secondsTenths(20))
    }

    @Test func metadataEnrichmentTakesStatusPriorityAfterManualRefreshBecomesSearchable() {
        var stats = SearchIndexStats()
        stats.isIndexing = true
        stats.isMetadataEnriching = true

        #expect(
            IndexStatusPhase.resolve(
                isManualRefreshInFlight: true,
                stats: stats
            ) == .enriching
        )
    }

    @Test func queryReadyResultsDoNotPresentPlaceholderMetadataAsRealValues() {
        let result = SearchResult(
            name: "zero-metadata.txt",
            path: "/tmp/zero-metadata.txt",
            isDirectory: false,
            size: 0,
            modified: Date(timeIntervalSinceReferenceDate: 0),
            created: Date(timeIntervalSinceReferenceDate: 0),
            matchedContent: false,
            contentPreview: nil
        )

        #expect(ResultMetadataDisplay.sizeText(for: result, metadataAvailable: false) == "—")
        #expect(!ResultMetadataDisplay.showsDates(metadataAvailable: false))
    }

    @Test func completedMetadataShowsFilesAndKnownPackageSizesButNotOrdinaryDirectories() {
        let modified = Date(timeIntervalSinceReferenceDate: 1)
        let file = SearchResult(
            name: "archive.bin",
            path: "/tmp/archive.bin",
            isDirectory: false,
            size: 2 * 1_000 * 1_000 * 1_000,
            modified: modified,
            created: modified,
            matchedContent: false,
            contentPreview: nil
        )
        let package = SearchResult(
            name: "Example.app",
            path: "/tmp/Example.app",
            isDirectory: true,
            size: 750 * 1_000 * 1_000,
            modified: modified,
            created: modified,
            matchedContent: false,
            contentPreview: nil
        )
        let directory = SearchResult(
            name: "Documents",
            path: "/tmp/Documents",
            isDirectory: true,
            size: 750 * 1_000 * 1_000,
            modified: modified,
            created: modified,
            matchedContent: false,
            contentPreview: nil
        )
        let packageWithInvalidMetadata = SearchResult(
            name: "Unindexed.app",
            path: "/tmp/Unindexed.app",
            isDirectory: true,
            size: 1,
            modified: modified,
            created: modified,
            matchedContent: false,
            contentPreview: nil
        )

        #expect(ResultMetadataDisplay.sizeText(for: file, metadataAvailable: true).contains("GB"))
        #expect(ResultMetadataDisplay.sizeText(for: package, metadataAvailable: true).contains("MB"))
        #expect(ResultMetadataDisplay.sizeText(for: directory, metadataAvailable: true) == "—")
        #expect(
            ResultMetadataDisplay.sizeText(
                for: packageWithInvalidMetadata,
                metadataAvailable: true
            ) == "—"
        )
    }

    @MainActor
    @Test func manualRefreshStartsWhileIndexStatusIsAlreadyUpdating() async throws {
        let probe = BuildInvocationProbe()
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenFind-ManualRefreshCache-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let store = SearchIndexStore(persistenceURL: cacheURL, buildOperation: { _ in
            probe.record()
            try? await Task.sleep(for: .milliseconds(60))
            return SearchIndexBuildResult(nodes: [], unresolvedPaths: [])
        })
        let viewModel = makeViewModel(indexStore: store)
        var indexingStats = SearchIndexStats()
        indexingStats.isIndexing = true
        viewModel.indexStats = indexingStats

        viewModel.refreshIndexNow()
        viewModel.refreshIndexNow()

        #expect(viewModel.isManualRefreshInFlight)
        for _ in 0..<100 where viewModel.isManualRefreshInFlight {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(!viewModel.isManualRefreshInFlight)
        #expect(probe.count == 1)
    }

    @MainActor
    @Test func searchConsumesEveryResultWhilePublishingBoundedPages() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenFind-PaginationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for index in 0..<5 {
            let url = root.appendingPathComponent("paged-result-\(index).txt")
            try Data("match".utf8).write(to: url)
        }

        let viewModel = makeViewModel(resultPageSize: 2)
        viewModel.scopes = [root]
        viewModel.options = SearchOptions(query: "paged-result-")
        viewModel.startSearch()

        for _ in 0..<300 where viewModel.isSearching {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!viewModel.isSearching)
        #expect(viewModel.totalResultCount == 5)
        #expect(viewModel.resultCount == 2)
        #expect(viewModel.hasMoreResults)
        #expect(viewModel.nextResultPageCount == 2)

        viewModel.showMoreResults()
        for _ in 0..<300 where viewModel.resultCount < 4 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(viewModel.resultCount == 4)
        #expect(viewModel.totalResultCount == 5)
        #expect(viewModel.nextResultPageCount == 1)

        viewModel.showMoreResults()
        for _ in 0..<300 where viewModel.resultCount < 5 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(viewModel.resultCount == 5)
        #expect(!viewModel.hasMoreResults)
        #expect(Set(viewModel.results.map(\.name)) == Set((0..<5).map { "paged-result-\($0).txt" }))
    }

    @MainActor
    @Test func automaticReplacementKeepsCompleteResultsBehindVisiblePage() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenFind-AutoPaginationTests-\(UUID().uuidString)", isDirectory: true)
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenFind-AutoPaginationCache-\(UUID().uuidString).bin")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: cacheURL)
        }

        for index in 0..<5 {
            try Data("match".utf8).write(
                to: root.appendingPathComponent("auto-paged-result-\(index).txt")
            )
        }

        let store = SearchIndexStore(persistenceURL: cacheURL)
        let viewModel = makeViewModel(resultPageSize: 2, indexStore: store)
        viewModel.scopes = [root]
        viewModel.options = SearchOptions(query: "auto-paged-result-")
        viewModel.startSearch()

        for _ in 0..<300 where viewModel.isSearching {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(viewModel.totalResultCount == 5)
        #expect(viewModel.resultCount == 2)

        viewModel.showMoreResults()
        for _ in 0..<100 where viewModel.isExpandingResults {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(viewModel.resultCount == 4)

        try Data("new match".utf8).write(
            to: root.appendingPathComponent("auto-paged-result-5.txt")
        )
        _ = await store.refresh(
            scopes: [root],
            deepIndex: viewModel.options.deepIndex,
            hasFullDiskAccess: true
        )
        viewModel.elapsed = 0.42
        viewModel.startSearch(
            recordRecent: false,
            clearResults: false,
            replaceResultsOnCompletion: true
        )

        // The previous visible page remains stable while the automatic pass
        // builds a complete replacement in the background. Its timer must not
        // overwrite the last visible search duration on every tick.
        #expect(viewModel.resultCount == 4)
        #expect(viewModel.isRefreshingSearchResults)
        #expect(viewModel.elapsed == 0.42)
        for _ in 0..<300 where viewModel.isSearching || viewModel.totalResultCount != 6 {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(!viewModel.isSearching)
        #expect(!viewModel.isRefreshingSearchResults)
        #expect(viewModel.totalResultCount == 6)
        #expect(viewModel.resultCount == 4)
        #expect(viewModel.elapsed == 0.42)
        for _ in 0..<10 where viewModel.hasMoreResults {
            viewModel.showMoreResults()
            for _ in 0..<100 where viewModel.isExpandingResults {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        #expect(viewModel.resultCount == 6)
    }

    @MainActor
    @Test func automaticReplacementPreservesInFlightPageExpansion() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenFind-QueuedPaginationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for index in 0..<5 {
            try Data("match".utf8).write(
                to: root.appendingPathComponent("queued-page-result-\(index).txt")
            )
        }

        let viewModel = makeViewModel(resultPageSize: 2)
        viewModel.scopes = [root]
        viewModel.options = SearchOptions(query: "queued-page-result-")
        viewModel.startSearch()
        for _ in 0..<300 where viewModel.isSearching {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(viewModel.resultCount == 2)
        #expect(viewModel.totalResultCount == 5)

        viewModel.showMoreResults()
        #expect(viewModel.isExpandingResults)
        viewModel.startSearch(
            recordRecent: false,
            clearResults: false,
            replaceResultsOnCompletion: true
        )

        for _ in 0..<300 where viewModel.isSearching
            || viewModel.isExpandingResults
            || viewModel.resultCount < 4 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(viewModel.resultCount == 4)
        #expect(viewModel.totalResultCount == 5)
        #expect(viewModel.nextResultPageCount == 1)
    }

    @MainActor
    @Test func indexRevisionRefreshAtomicallyReplacesStaleVisibleResults() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenFind-RevisionViewModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let staleURL = root.appendingPathComponent("stale-result.txt")
        let viewModel = makeViewModel(automaticSearchQuietPeriod: .milliseconds(50))
        viewModel.scopes = [root]
        viewModel.options = SearchOptions(query: "revision-probe")
        viewModel.results = [SearchResult(
            name: staleURL.lastPathComponent,
            path: staleURL.path(percentEncoded: false),
            isDirectory: false,
            size: 0,
            modified: .now,
            created: .now,
            matchedContent: false,
            contentPreview: nil
        )]
        var previousStats = SearchIndexStats()
        previousStats.indexRevision = 1
        viewModel.indexStats = previousStats

        var updatedStats = previousStats
        updatedStats.indexRevision = 2
        viewModel.handleStatsTick(updatedStats, fullDiskAccess: true)

        // Keep the last complete snapshot visible while the replacement pass
        // runs; clearing here makes whole-Mac searches flicker or starve under
        // a continuous FSEvents stream.
        #expect(viewModel.resultCount == 1)

        for _ in 0..<300 where viewModel.isSearching || viewModel.resultCount != 0 {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(!viewModel.isSearching)
        #expect(viewModel.results.isEmpty)
        viewModel.cancel()
    }

    @MainActor
    @Test func irrelevantExactRevisionDoesNotRestartAPlainNameSearch() {
        let viewModel = makeViewModel()
        viewModel.options = SearchOptions(query: "needle")
        var previousStats = SearchIndexStats()
        previousStats.indexRevision = 10
        viewModel.indexStats = previousStats

        var updatedStats = previousStats
        updatedStats.indexRevision = 11
        viewModel.handleStatsTick(
            updatedStats,
            changes: SearchIndexChanges(
                subtreeReplacements: [],
                exactReplacements: [SearchIndexExactReplacement(
                    path: "/tmp/unrelated.txt",
                    node: TempNode(
                        path: "/tmp/unrelated.txt",
                        name: "unrelated.txt",
                        isDirectory: false,
                        size: 0,
                        modifiedTime: 0,
                        creationTime: 0,
                        isHiddenScope: false,
                        isPackageDescendant: false
                    )
                )],
                requiresConservativeRefresh: false
            ),
            fullDiskAccess: true
        )

        #expect(!viewModel.isSearching)
        viewModel.cancel()
    }

    @MainActor
    @Test func matchingExactRevisionTriggersAnAtomicRefresh() {
        let viewModel = makeViewModel()
        viewModel.options = SearchOptions(query: "needle")
        var previousStats = SearchIndexStats()
        previousStats.indexRevision = 20
        viewModel.indexStats = previousStats

        var updatedStats = previousStats
        updatedStats.indexRevision = 21
        viewModel.handleStatsTick(
            updatedStats,
            changes: SearchIndexChanges(
                subtreeReplacements: [],
                exactReplacements: [SearchIndexExactReplacement(
                    path: "/tmp/new-needle.txt",
                    node: TempNode(
                        path: "/tmp/new-needle.txt",
                        name: "new-needle.txt",
                        isDirectory: false,
                        size: 0,
                        modifiedTime: 0,
                        creationTime: 0,
                        isHiddenScope: false,
                        isPackageDescendant: false
                    )
                )],
                requiresConservativeRefresh: false
            ),
            fullDiskAccess: true
        )

        #expect(viewModel.isSearching)
        viewModel.cancel()
    }

    @MainActor
    @Test func removedMatchingExactRevisionStillTriggersARefresh() {
        let viewModel = makeViewModel()
        viewModel.options = SearchOptions(query: "needle")
        var previousStats = SearchIndexStats()
        previousStats.indexRevision = 25
        viewModel.indexStats = previousStats

        var updatedStats = previousStats
        updatedStats.indexRevision = 26
        viewModel.handleStatsTick(
            updatedStats,
            changes: SearchIndexChanges(
                subtreeReplacements: [],
                exactReplacements: [SearchIndexExactReplacement(
                    path: "/tmp/removed-needle.txt",
                    node: nil
                )],
                requiresConservativeRefresh: false
            ),
            fullDiskAccess: true
        )

        #expect(viewModel.isSearching)
        viewModel.cancel()
    }

    @MainActor
    @Test func subtreeRevisionWaitsForQuietPeriodBeforeCompletenessRefresh() async throws {
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenFind-QuietRefreshCache-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let store = SearchIndexStore(persistenceURL: cacheURL, buildOperation: { _ in
            try? await Task.sleep(for: .milliseconds(200))
            return SearchIndexBuildResult(nodes: [], unresolvedPaths: [])
        })
        let viewModel = makeViewModel(
            indexStore: store,
            automaticSearchQuietPeriod: .milliseconds(50)
        )
        viewModel.options = SearchOptions(query: "needle")
        var previousStats = SearchIndexStats()
        previousStats.indexRevision = 30
        viewModel.indexStats = previousStats

        var updatedStats = previousStats
        updatedStats.indexRevision = 31
        viewModel.handleStatsTick(
            updatedStats,
            changes: SearchIndexChanges(
                subtreeReplacements: [SearchIndexReplacement(
                    rootPath: "/tmp/changed-directory",
                    nodes: []
                )],
                exactReplacements: [],
                requiresConservativeRefresh: false
            ),
            fullDiskAccess: true
        )

        #expect(!viewModel.isSearching)
        try await Task.sleep(for: .milliseconds(80))
        #expect(viewModel.isSearching)
        viewModel.cancel()
    }

    @MainActor
    @Test func unavailablePathsStayQuietWhenIndexIsSearchable() {
        let viewModel = makeViewModel()
        viewModel.hasFullDiskAccess = true
        var stats = SearchIndexStats()
        stats.unavailablePaths = 3
        viewModel.indexStats = stats

        #expect(!viewModel.shouldShowReadinessGuidance)
    }

    @MainActor
    @Test func metadataEnrichmentIsSearchableInsteadOfAnIncompleteIndexState() {
        let viewModel = makeViewModel()
        viewModel.options.query = "needle"
        var stats = SearchIndexStats()
        stats.indexedFiles = 42
        stats.isIndexing = true
        stats.isMetadataEnriching = true
        viewModel.indexStats = stats

        #expect(viewModel.shouldShowReadinessGuidance)
        #expect(!viewModel.shouldShowSearchIncompleteState)

        viewModel.indexStats.isMetadataEnriching = false
        #expect(viewModel.shouldShowSearchIncompleteState)
    }

    @MainActor
    @Test func fullDiskAccessChangeRepreparesIndexWithNewPermissionSignature() async throws {
        let probe = BuildInvocationProbe()
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenFind-PermissionRefreshCache-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let store = SearchIndexStore(persistenceURL: cacheURL, buildOperation: { _ in
            probe.record()
            return SearchIndexBuildResult(nodes: [], unresolvedPaths: [])
        })
        let viewModel = makeViewModel(indexStore: store)
        viewModel.hasFullDiskAccess = false

        viewModel.handleStatsTick(viewModel.indexStats, fullDiskAccess: true)

        for _ in 0..<100 where probe.count == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(viewModel.hasFullDiskAccess)
        #expect(probe.count == 1)
    }
}

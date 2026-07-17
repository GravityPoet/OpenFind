import Foundation
import Observation

enum SearchDisplayMode: String, Sendable {
    case files
    case events
}

/// UI state and search lifecycle. All state lives on the main actor and is
/// observed directly by SwiftUI. Durable options and search scopes are loaded
/// on init and persisted as they change.
@MainActor
@Observable
final class SearchViewModel {

    var options: SearchOptions {
        didSet {
            if displayMode == .events, oldValue.query != options.query {
                refreshFilteredEventEntries()
            }
        }
    }
    var scopes: [URL]
    var results: [SearchResult] = []
    var eventEntries: [FileSystemEventLogEntry] = [] {
        didSet {
            if displayMode == .events {
                refreshFilteredEventEntries()
            }
        }
    }
    private(set) var filteredEventEntries: [FileSystemEventLogEntry] = []
    var displayMode: SearchDisplayMode = .files
    var recentSearches: [String]
    var hasFullDiskAccess = true

    var isSearching = false
    var isBroadContentSearchBlocked = false
    var searchErrorMessage: String?
    var elapsed: TimeInterval = 0
    var indexStats = SearchIndexStats()
    private(set) var unavailablePaths: [String] = []
    private(set) var totalResultCount = 0
    private(set) var isRefreshingSearchResults = false
    private(set) var isManualRefreshInFlight = false
    private(set) var isExpandingResults = false

    /// Search always retains the complete ordered result set. Only this bounded
    /// number of rows is materialized for SwiftUI at a time, keeping large
    /// result sets responsive without dropping matches.
    private let resultPageSize: Int
    /// Once the first visible page is full, avoid a main-actor publication for
    /// every tiny stream batch. The complete result buffer still receives
    /// every match; this stride only controls UI progress notifications.
    private let resultPublishStride: Int
    @ObservationIgnored private var visibleResultLimit: Int
    @ObservationIgnored private var completeResults: [SearchResult] = []
    @ObservationIgnored private var completeNameSnapshot: SearchNameResultSnapshot?
    @ObservationIgnored private var nameSnapshotOffset = 0
    @ObservationIgnored private var staleNameResultCount = 0
    @ObservationIgnored private var excludedNameResultIdentities: Set<ResolvedNodeIdentity> = []
    private let indexStore: SearchIndexStore
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var automaticSearchTask: Task<Void, Never>?
    @ObservationIgnored private var elapsedTask: Task<Void, Never>?
    @ObservationIgnored private var indexStatsTask: Task<Void, Never>?
    @ObservationIgnored private var manualRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var resultPageTask: Task<Void, Never>?
    @ObservationIgnored private var pendingResultPageExpansions = 0
    private var startedAt: ContinuousClock.Instant?
    private var elapsedBeforeCurrentPass: TimeInterval = 0
    private var publishesLiveElapsed = true
    private var allowBroadContentSearch = false
    private var authorizedBroadSearch: BroadSearchFingerprint?
    private var searchGeneration = 0
    /// Item count at the last auto re-search, so a growing index re-runs the
    /// current query at most once per observed growth tick.
    private var lastAutoSearchItems = -1
    private var lastAutomaticSearchCompletedAt: ContinuousClock.Instant?
    private let automaticSearchMinimumInterval: TimeInterval = 2
    private let automaticSearchQuietPeriod: Duration
    /// Set when the index finishes while a search is still running: that search
    /// saw only a partial index, so re-run once it completes. `justFinished`
    /// fires on a single stats tick and would otherwise be lost.
    private var pendingFinalAutoSearch = false
    private var pendingAutomaticSearchRequiresQuietPeriod = false

    private struct BroadSearchFingerprint: Equatable {
        let options: SearchOptions
        let scopes: [String]
    }

    private enum RevisionRefreshDisposition {
        case none
        case immediate
        case afterQuietPeriod
    }

    init(
        indexStore: SearchIndexStore = .shared,
        startIndexing: Bool = true,
        resultPageSize: Int = 2_000,
        automaticSearchQuietPeriod: Duration = .seconds(3)
    ) {
        let pageSize = max(1, resultPageSize)
        self.resultPageSize = pageSize
        resultPublishStride = max(pageSize, 512)
        visibleResultLimit = pageSize
        self.indexStore = indexStore
        self.automaticSearchQuietPeriod = automaticSearchQuietPeriod
        options = Preferences.loadOptions()
        let stored = ScopeStore.load()
        scopes = stored.isEmpty ? [SearchScopes.wholeMacURL] : stored
        recentSearches = Preferences.recentSearches
        hasFullDiskAccess = SearchPermissions.hasFullDiskAccess()
        if startIndexing {
            refreshIndex()
            startIndexStatsObserver()
        }
    }

    var canSearch: Bool {
        !options.query.trimmingCharacters(in: .whitespaces).isEmpty && !scopes.isEmpty
    }

    var resultCount: Int { results.count }

    var hasMoreResults: Bool {
        resultCount < totalResultCount
    }

    var nextResultPageCount: Int {
        min(resultPageSize, max(0, totalResultCount - resultCount))
    }

    private func refreshFilteredEventEntries() {
        let query = options.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        filteredEventEntries = query.isEmpty
            ? eventEntries
            : eventEntries.filter { $0.matchesQuery.contains(query) }
    }

    var searchPlaceholderKey: String {
        switch displayMode {
        case .files:
            return "Search files and folders..."
        case .events:
            return "Filter events by path or name..."
        }
    }

    var isIndexingActiveScope: Bool {
        indexStats.isIndexing
    }

    var shouldShowSearchIncompleteState: Bool {
        canSearch && results.isEmpty && indexStats.isIndexing && !indexStats.isMetadataEnriching
    }

    var shouldShowReadinessGuidance: Bool {
        !hasFullDiskAccess || indexStats.isIndexing
    }

    /// Debounced trigger for query/option changes: search only fires after
    /// 350 ms without further changes. Durable options are persisted here.
    func scheduleSearch(delay: Duration = .milliseconds(350)) {
        Preferences.saveOptions(options)
        if displayMode == .events {
            debounceTask?.cancel()
            return
        }
        allowBroadContentSearch = false
        authorizedBroadSearch = nil
        debounceTask?.cancel()
        guard canSearch else {
            cancel()
            resetResults()
            elapsed = 0
            elapsedBeforeCurrentPass = 0
            startedAt = nil
            isBroadContentSearchBlocked = false
            searchErrorMessage = nil
            return
        }
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.startSearch()
        }
    }

    /// Starts a new search, cancelling any previous one. Auto re-searches
    /// (fired while the index is still filling) preserve existing rows so the
    /// table does not flicker empty between partial-index passes.
    func startSearch(
        recordRecent: Bool = true,
        clearResults: Bool = true,
        replaceResultsOnCompletion: Bool = false
    ) {
        displayMode = .files
        guard canSearch else { return }
        pendingFinalAutoSearch = false
        debounceTask?.cancel()
        cancel(preservingResultPageExpansion: replaceResultsOnCompletion)
        refreshIndex()
        guard validateQuery(clearResults: clearResults) else { return }

        if SearchScopeGuard.needsBroadContentConfirmation(options: options, scopes: scopes),
           !allowBroadContentSearch,
            authorizedBroadSearch != broadSearchFingerprint() {
            if clearResults {
                resetResults()
                elapsed = 0
                elapsedBeforeCurrentPass = 0
            }
            isBroadContentSearchBlocked = true
            return
        }

        isBroadContentSearchBlocked = false
        searchErrorMessage = nil
        allowBroadContentSearch = false
        if recordRecent { recordRecentSearch() }
        let currentOptions = options
        let currentScopes = scopes
        let usesCompactNameSnapshot = SearchEngine.supportsCompactNameSnapshot(options: currentOptions)
        let desiredVisibleResultCount = replaceResultsOnCompletion
            ? max(resultPageSize, results.count)
            : resultPageSize
        let generation = searchGeneration
        if clearResults {
            resetResults()
            elapsed = 0
            elapsedBeforeCurrentPass = 0
        } else if replaceResultsOnCompletion && !usesCompactNameSnapshot {
            // The visible page is an independent value array, so it can remain
            // stable while this backing buffer is reused for the replacement.
            // Retaining both complete million-row snapshots would double peak
            // memory during every automatic reconciliation pass.
            completeResults.removeAll(keepingCapacity: false)
            elapsedBeforeCurrentPass = 0
        } else {
            synchronizeCompleteResultsWithVisibleRowsIfNeeded()
            elapsedBeforeCurrentPass = elapsed
        }
        isRefreshingSearchResults = replaceResultsOnCompletion
        publishesLiveElapsed = !replaceResultsOnCompletion
        isSearching = true
        startedAt = .now
        startElapsedClock()

        searchTask = Task { [weak self] in
            await self?.consume(
                scopes: currentScopes,
                options: currentOptions,
                usesCompactNameSnapshot: usesCompactNameSnapshot,
                desiredVisibleResultCount: desiredVisibleResultCount,
                replaceResultsOnCompletion: replaceResultsOnCompletion,
                generation: generation
            )
        }
    }

    func startBroadContentSearchAnyway() {
        allowBroadContentSearch = true
        authorizedBroadSearch = broadSearchFingerprint()
        startSearch()
    }

    /// Cancels the current search, keeping any results already found.
    func cancel() {
        cancel(preservingResultPageExpansion: false)
    }

    private func cancel(preservingResultPageExpansion: Bool) {
        if preservingResultPageExpansion, isExpandingResults {
            if pendingResultPageExpansions < Int.max {
                pendingResultPageExpansions += 1
            }
        } else if !preservingResultPageExpansion {
            pendingResultPageExpansions = 0
        }
        searchGeneration &+= 1
        pendingFinalAutoSearch = false
        pendingAutomaticSearchRequiresQuietPeriod = false
        automaticSearchTask?.cancel()
        automaticSearchTask = nil
        searchTask?.cancel()
        searchTask = nil
        resultPageTask?.cancel()
        resultPageTask = nil
        isExpandingResults = false
        stopElapsedClock()
        if isSearching {
            if isRefreshingSearchResults, completeNameSnapshot == nil {
                // The replacement buffer may contain a partial new snapshot.
                // On an explicit stop, retain the stable visible page and make
                // its count authoritative rather than exposing a mixed tail.
                completeResults = results
                totalResultCount = results.count
                visibleResultLimit = max(visibleResultLimit, results.count)
            }
            finish(publishElapsed: publishesLiveElapsed)
        }
    }

    func showMoreResults() {
        guard hasMoreResults else {
            pendingResultPageExpansions = 0
            return
        }
        if isRefreshingSearchResults {
            if pendingResultPageExpansions < Int.max {
                pendingResultPageExpansions += 1
            }
            return
        }
        guard !isExpandingResults else { return }
        if let snapshot = completeNameSnapshot {
            let generation = searchGeneration
            let startingOffset = nameSnapshotOffset
            let excludedIdentities = excludedNameResultIdentities
            let pageSize = resultPageSize
            isExpandingResults = true
            resultPageTask = Task { [weak self] in
                let page = await SearchEngine.materializeNamePage(
                    from: snapshot,
                    startingAt: startingOffset,
                    count: pageSize,
                    excluding: excludedIdentities
                )
                guard let self else { return }
                guard !Task.isCancelled,
                      generation == searchGeneration,
                      nameSnapshotOffset == startingOffset else {
                    resultPageTask = nil
                    isExpandingResults = false
                    return
                }
                results.append(contentsOf: page.results)
                nameSnapshotOffset = page.nextOffset
                staleNameResultCount += page.staleResultCount
                totalResultCount = max(
                    results.count,
                    snapshot.count - staleNameResultCount - excludedNameResultIdentities.count
                )
                if nameSnapshotOffset >= snapshot.count {
                    totalResultCount = results.count
                }
                let (expandedLimit, overflow) = visibleResultLimit.addingReportingOverflow(resultPageSize)
                visibleResultLimit = overflow ? Int.max : expandedLimit
                resultPageTask = nil
                isExpandingResults = false
                runPendingResultPageExpansionIfNeeded()
            }
            return
        }
        let (expandedLimit, overflow) = visibleResultLimit.addingReportingOverflow(resultPageSize)
        visibleResultLimit = overflow ? Int.max : expandedLimit
        publishVisibleResults()
        runPendingResultPageExpansionIfNeeded()
    }

    private func runPendingResultPageExpansionIfNeeded() {
        guard pendingResultPageExpansions > 0 else { return }
        guard hasMoreResults else {
            pendingResultPageExpansions = 0
            return
        }
        guard !isSearching, !isRefreshingSearchResults, !isExpandingResults else { return }
        pendingResultPageExpansions -= 1
        showMoreResults()
    }

    func setScopes(_ newScopes: [URL]) {
        authorizedBroadSearch = nil
        for scope in scopes {
            ScopeStore.releaseAccess(scope)
        }
        scopes = newScopes
        ScopeStore.save(scopes)
        refreshIndex()
    }

    func addScope(_ url: URL) {
        let newScopes = SearchScopes.adding(url, to: scopes)
        guard newScopes != scopes else { return }
        authorizedBroadSearch = nil
        for scope in scopes where !newScopes.contains(scope) {
            ScopeStore.releaseAccess(scope)
        }
        scopes = newScopes
        ScopeStore.save(scopes)
        refreshIndex()
    }

    func removeScopes(_ offsets: IndexSet) {
        authorizedBroadSearch = nil
        for index in offsets where scopes.indices.contains(index) {
            ScopeStore.releaseAccess(scopes[index])
        }
        scopes.remove(atOffsets: offsets)
        ScopeStore.save(scopes)
        refreshIndex()
    }

    func applyRecentSearch(_ query: String) {
        options.query = query
        startSearch()
    }

    func clearRecentSearches() {
        Preferences.clearRecentSearches()
        recentSearches = []
    }

    func showFiles() {
        displayMode = .files
        eventEntries.removeAll(keepingCapacity: false)
        filteredEventEntries.removeAll(keepingCapacity: false)
        if canSearch {
            scheduleSearch(delay: .zero)
        }
    }

    func showEvents() {
        displayMode = .events
        debounceTask?.cancel()
        isBroadContentSearchBlocked = false
        searchErrorMessage = nil
        refreshFilteredEventEntries()
        refreshEventLog()
    }

    func flushIndexPersistence() async {
        await indexStore.flushPersistence()
    }

    func refreshIndexNow() {
        guard manualRefreshTask == nil else { return }
        debounceTask?.cancel()
        cancel()
        isManualRefreshInFlight = true

        var refreshingStats = indexStats
        refreshingStats.isIndexing = true
        if indexStats != refreshingStats {
            indexStats = refreshingStats
        }

        let currentScopes = scopes
        let deepIndex = options.deepIndex
        let indexStore = self.indexStore
        manualRefreshTask = Task { [weak self] in
            let fda = SearchPermissions.hasFullDiskAccess()
            let stats = await indexStore.refresh(
                scopes: currentScopes,
                deepIndex: deepIndex,
                hasFullDiskAccess: fda
            )
            await MainActor.run {
                guard let self else { return }
                self.manualRefreshTask = nil
                self.isManualRefreshInFlight = false
                self.hasFullDiskAccess = fda
                if self.indexStats != stats {
                    self.indexStats = stats
                }
                if self.displayMode == .files, self.canSearch {
                    self.startSearch(recordRecent: false, clearResults: true)
                }
            }
        }
    }

    func moveResultsToTrash(_ urls: [URL]) {
        let selected = Array(Set(urls))
        guard !selected.isEmpty else { return }
        let selectedPaths = Set(selected.map {
            SearchPath.canonicalAliasPath($0.path(percentEncoded: false))
        })
        let selectedIdentitiesByPath = Dictionary(
            uniqueKeysWithValues: results.compactMap { result in
                let path = SearchPath.canonicalAliasPath(result.path)
                return selectedPaths.contains(path) ? (path, result.resolvedIdentity) : nil
            }
        )

        FileActions.moveToTrash(selected) { [weak self] movedURLs in
            guard let self, !movedURLs.isEmpty else { return }
            let moved = Set(movedURLs.map { SearchPath.canonicalAliasPath($0.path(percentEncoded: false)) })
            if let snapshot = self.completeNameSnapshot {
                self.excludedNameResultIdentities.formUnion(
                    moved.compactMap { selectedIdentitiesByPath[$0] }
                )
                self.results.removeAll { moved.contains(SearchPath.canonicalAliasPath($0.path)) }
                self.totalResultCount = max(
                    self.results.count,
                    snapshot.count
                        - self.staleNameResultCount
                        - self.excludedNameResultIdentities.count
                )
                return
            }
            self.synchronizeCompleteResultsWithVisibleRowsIfNeeded()
            self.completeResults.removeAll { moved.contains(SearchPath.canonicalAliasPath($0.path)) }
            self.totalResultCount = self.completeResults.count
            self.publishVisibleResults()
        }
    }

    private func recordRecentSearch() {
        Preferences.addRecentSearch(options.query)
        recentSearches = Preferences.recentSearches
    }

    private func validateQuery(clearResults: Bool) -> Bool {
        do {
            _ = try SearchQueryPlan.parse(options.query).compile(options: options)
            searchErrorMessage = nil
            return true
        } catch {
            if clearResults {
                resetResults()
                elapsed = 0
                elapsedBeforeCurrentPass = 0
            }
            isBroadContentSearchBlocked = false
            searchErrorMessage = L("Invalid search expression")
            return false
        }
    }

    private func consume(
        scopes: [URL],
        options: SearchOptions,
        usesCompactNameSnapshot: Bool,
        desiredVisibleResultCount: Int,
        replaceResultsOnCompletion: Bool,
        generation: Int
    ) async {
        if usesCompactNameSnapshot,
           let snapshot = await SearchEngine.nameResultSnapshot(
               scopes: scopes,
               options: options,
               store: indexStore
           ) {
            let page = await SearchEngine.materializeNamePage(
                from: snapshot,
                startingAt: 0,
                count: desiredVisibleResultCount
            )
            guard !Task.isCancelled, generation == searchGeneration else { return }

            completeNameSnapshot = snapshot
            completeResults.removeAll(keepingCapacity: false)
            nameSnapshotOffset = page.nextOffset
            staleNameResultCount = page.staleResultCount
            excludedNameResultIdentities.removeAll(keepingCapacity: false)
            results = page.results
            visibleResultLimit = max(resultPageSize, results.count)
            totalResultCount = max(results.count, snapshot.count - staleNameResultCount)
            if nameSnapshotOffset >= snapshot.count {
                totalResultCount = results.count
            }
            finish(publishElapsed: !replaceResultsOnCompletion)
            if replaceResultsOnCompletion {
                lastAutomaticSearchCompletedAt = .now
            }
            runPendingResultPageExpansionIfNeeded()
            runPendingAutoSearchIfNeeded()
            return
        }

        guard !Task.isCancelled, generation == searchGeneration else { return }
        var pending: [SearchResult] = []
        pending.reserveCapacity(64)
        // SearchEngine already guarantees a unique stream. Keep an additional
        // path set only for the legacy merge mode that intentionally appends to
        // an existing result buffer; allocating another two-million-entry set
        // for a normal whole-Mac search needlessly doubles peak memory.
        var streamedPaths: Set<String>? = !replaceResultsOnCompletion && !completeResults.isEmpty
            ? Set(completeResults.map { SearchPath.canonicalAliasPath($0.path) })
            : nil

        let stream = SearchEngine.searchBatches(scopes: scopes, options: options, store: indexStore)
        for await batch in stream {
            if Task.isCancelled || generation != searchGeneration { break }
            if streamedPaths == nil {
                if replaceResultsOnCompletion {
                    completeResults.append(contentsOf: batch)
                } else {
                    pending.append(contentsOf: batch)
                }
            } else {
                for result in batch {
                    if Task.isCancelled || generation != searchGeneration { break }
                    let path = SearchPath.canonicalIndexedPath(result.path)
                    guard streamedPaths!.insert(path).inserted else { continue }
                    pending.append(result)
                }
            }
            if !replaceResultsOnCompletion, pending.count >= 48 {
                flush(&pending, generation: generation)
            }
        }
        if replaceResultsOnCompletion {
            if !Task.isCancelled, generation == searchGeneration {
                clearNameSnapshot()
                totalResultCount = completeResults.count
                publishVisibleResults()
            }
        } else {
            if !Task.isCancelled, generation == searchGeneration {
                clearNameSnapshot()
                flush(&pending, generation: generation)
                // The trailing publication is authoritative even when the
                // last throttled progress tick was below the stride.
                totalResultCount = completeResults.count
                publishVisibleResults()
            }
        }
        if !Task.isCancelled, generation == searchGeneration {
            // An automatic replacement is background synchronization, not a
            // user search. Keep the last visible query duration authoritative.
            finish(publishElapsed: !replaceResultsOnCompletion)
            if replaceResultsOnCompletion {
                lastAutomaticSearchCompletedAt = .now
            }
            runPendingResultPageExpansionIfNeeded()
            runPendingAutoSearchIfNeeded()
        }
    }

    /// Follow-up for a search that ran against a still-filling index: once the
    /// index finished mid-search, re-run so results cover the whole index.
    private func runPendingAutoSearchIfNeeded() {
        guard pendingFinalAutoSearch else { return }
        guard canSearch, !isBroadContentSearchBlocked else { return }
        // Let a user-requested page expansion finish before replacing the
        // snapshot. Starting the replacement here would cancel the page task,
        // force it back into the queue, and do needless duplicate work.
        guard !isExpandingResults else { return }
        if pendingAutomaticSearchRequiresQuietPeriod {
            if automaticSearchTask == nil {
                scheduleBroadAutomaticSearchAfterQuietPeriod()
            }
            return
        }
        // A long broad query must not immediately start over against every
        // intermediate index revision. Keep the flag and run one authoritative
        // pass only after the event stream has stayed quiet.
        if totalResultCount >= SearchEngine.maximumFullyValidatedNameMatches {
            scheduleBroadAutomaticSearchAfterQuietPeriod()
            return
        }
        pendingFinalAutoSearch = false
        requestAutomaticSearch()
    }

    private func scheduleBroadAutomaticSearchAfterQuietPeriod() {
        pendingFinalAutoSearch = true
        pendingAutomaticSearchRequiresQuietPeriod = true
        automaticSearchTask?.cancel()
        automaticSearchTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: automaticSearchQuietPeriod)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            automaticSearchTask = nil
            // A later stats tick will restart the quiet-period timer. If the
            // current search is still draining, its completion does the same.
            guard pendingFinalAutoSearch,
                  !indexStats.isIndexing,
                  !isSearching,
                  canSearch,
                  !isBroadContentSearchBlocked else { return }
            pendingFinalAutoSearch = false
            pendingAutomaticSearchRequiresQuietPeriod = false
            startAutomaticSearch()
        }
    }

    /// Coalesces a busy event stream into bounded trailing refreshes. Each
    /// automatic pass replaces results atomically on completion, so deletions
    /// disappear without blanking the table while a whole-Mac search runs.
    private func requestAutomaticSearch() {
        guard displayMode == .files, canSearch, !isBroadContentSearchBlocked else { return }
        if isSearching {
            pendingFinalAutoSearch = true
            return
        }

        let elapsedSinceLast = lastAutomaticSearchCompletedAt.map {
            Self.seconds(in: $0.duration(to: .now))
        }
            ?? automaticSearchMinimumInterval
        let delay = max(0, automaticSearchMinimumInterval - elapsedSinceLast)
        if delay == 0 {
            startAutomaticSearch()
            return
        }
        guard automaticSearchTask == nil else { return }
        automaticSearchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(delay * 1_000)))
            guard !Task.isCancelled else { return }
            self?.automaticSearchTask = nil
            self?.startAutomaticSearch()
        }
    }

    private func startAutomaticSearch() {
        guard displayMode == .files, canSearch, !isSearching, !isBroadContentSearchBlocked else {
            return
        }
        let hasVisibleSnapshot = !results.isEmpty
            || !completeResults.isEmpty
            || totalResultCount > 0
        startSearch(
            recordRecent: false,
            clearResults: !hasVisibleSnapshot,
            replaceResultsOnCompletion: hasVisibleSnapshot
        )
    }

    /// Merges a buffered batch into the complete result set. Publishing to
    /// SwiftUI remains page-bounded, but the stream is never truncated.
    private func flush(_ pending: inout [SearchResult], generation: Int) {
        guard generation == searchGeneration, !pending.isEmpty else { return }
        completeResults.append(contentsOf: pending)
        let firstPageStillGrowing = results.count < visibleResultLimit
        let enoughNewResults = completeResults.count - totalResultCount >= resultPublishStride
        if firstPageStillGrowing || enoughNewResults {
            totalResultCount = completeResults.count
            appendNewlyVisibleResults()
        }
        pending.removeAll(keepingCapacity: true)
    }

    private func resetResults() {
        resultPageTask?.cancel()
        resultPageTask = nil
        isExpandingResults = false
        pendingResultPageExpansions = 0
        clearNameSnapshot()
        completeResults.removeAll(keepingCapacity: false)
        results.removeAll(keepingCapacity: false)
        totalResultCount = 0
        visibleResultLimit = resultPageSize
    }

    /// Some tests and UI recovery paths can seed visible rows directly. Fold
    /// those rows into the complete set before a non-clearing search starts.
    private func synchronizeCompleteResultsWithVisibleRowsIfNeeded() {
        guard completeNameSnapshot == nil else { return }
        guard completeResults.count < results.count else { return }
        completeResults = results
        totalResultCount = completeResults.count
        visibleResultLimit = max(visibleResultLimit, results.count)
    }

    private func publishVisibleResults() {
        let upperBound = min(visibleResultLimit, completeResults.count)
        results = Array(completeResults.prefix(upperBound))
    }

    private func appendNewlyVisibleResults() {
        let upperBound = min(visibleResultLimit, completeResults.count)
        guard results.count < upperBound else { return }
        results.append(contentsOf: completeResults[results.count..<upperBound])
    }

    private func clearNameSnapshot() {
        completeNameSnapshot = nil
        nameSnapshotOffset = 0
        staleNameResultCount = 0
        excludedNameResultIdentities.removeAll(keepingCapacity: false)
    }

    private func finish(publishElapsed: Bool) {
        if publishElapsed {
            updateElapsed(forcePublish: true)
        }
        isSearching = false
        stopElapsedClock()
        startedAt = nil
        isRefreshingSearchResults = false
        publishesLiveElapsed = true
    }

    private func startElapsedClock() {
        elapsedTask?.cancel()
        elapsedTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                self?.updateElapsed()
            }
        }
    }

    private func stopElapsedClock() {
        elapsedTask?.cancel()
        elapsedTask = nil
    }

    private func updateElapsed(forcePublish: Bool = false) {
        guard forcePublish || publishesLiveElapsed, let startedAt else { return }
        elapsed = elapsedBeforeCurrentPass + max(0, Self.seconds(in: startedAt.duration(to: .now)))
    }

    private static func seconds(in duration: Duration) -> TimeInterval {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }

    private func refreshIndex(fullDiskAccess knownFullDiskAccess: Bool? = nil) {
        let currentScopes = scopes
        let deepIndex = options.deepIndex
        let indexStore = self.indexStore
        Task { [weak self] in
            let fda = knownFullDiskAccess ?? SearchPermissions.hasFullDiskAccess()
            let stats = await indexStore.prepare(
                scopes: currentScopes,
                deepIndex: deepIndex,
                hasFullDiskAccess: fda
            )
            await MainActor.run {
                self?.handleStatsTick(
                    stats,
                    changes: nil,
                    fullDiskAccess: fda,
                    authoritativeRefreshCompleted: true
                )
            }
        }
    }

    private func broadSearchFingerprint() -> BroadSearchFingerprint {
        BroadSearchFingerprint(
            options: options,
            scopes: scopes.map { SearchPath.canonicalAliasPath($0.path(percentEncoded: false)) }
        )
    }

    private func startIndexStatsObserver() {
        indexStatsTask?.cancel()
        indexStatsTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let revision = self?.indexStats.indexRevision else { return }
                let observation = await self?.indexStore.observation(
                    since: revision
                )
                guard let observation else { return }
                let shouldRefreshEventLog = self?.displayMode == .events
                let events: [FileSystemEventLogEntry]? = if shouldRefreshEventLog {
                    await self?.indexStore.recentEventLog()
                } else {
                    nil
                }
                let unavailablePaths = await self?.indexStore.unavailablePathDiagnostics() ?? []
                let fda = SearchPermissions.hasFullDiskAccess()
                await MainActor.run {
                    guard let self else { return }
                    if let events,
                       self.displayMode == .events,
                       (self.eventEntries.count != events.count
                        || self.eventEntries.last?.id != events.last?.id) {
                        self.eventEntries = events
                    }
                    if self.unavailablePaths != unavailablePaths {
                        self.unavailablePaths = unavailablePaths
                    }
                    self.handleStatsTick(
                        observation.stats,
                        changes: observation.changes,
                        fullDiskAccess: fda
                    )
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Applies a stats tick and, while an initial build is filling the index,
    /// re-runs the current query so new results stream in as they are scanned.
    func handleStatsTick(
        _ stats: SearchIndexStats,
        changes: SearchIndexChanges? = nil,
        fullDiskAccess: Bool,
        authoritativeRefreshCompleted: Bool = false
    ) {
        let wasIndexing = indexStats.isIndexing
        let revisionChanged = stats.indexRevision != indexStats.indexRevision
        let statsChanged = stats != indexStats
        let permissionChanged = hasFullDiskAccess != fullDiskAccess
        if permissionChanged {
            hasFullDiskAccess = fullDiskAccess
            // The permission bit is part of the index signature. Updating the
            // banner alone would retain an intentionally reduced snapshot
            // after the user grants Full Disk Access.
            refreshIndex(fullDiskAccess: fullDiskAccess)
        }
        guard statsChanged else { return }
        indexStats = stats

        let stillGrowing = stats.isIndexing && stats.indexedItems != lastAutoSearchItems
        let justFinished = wasIndexing && !stats.isIndexing
        let revisionRefresh = revisionChanged
            ? revisionRefreshDisposition(for: changes)
            : .none
        guard stillGrowing
            || justFinished
            || authoritativeRefreshCompleted
            || revisionRefresh != .none else { return }
        guard displayMode == .files else { return }
        guard canSearch, !isBroadContentSearchBlocked else { return }
        lastAutoSearchItems = stats.indexedItems

        if !authoritativeRefreshCompleted, revisionRefresh == .afterQuietPeriod {
            scheduleBroadAutomaticSearchAfterQuietPeriod()
            return
        }
        if totalResultCount >= SearchEngine.maximumFullyValidatedNameMatches {
            scheduleBroadAutomaticSearchAfterQuietPeriod()
            return
        }
        requestAutomaticSearch()
    }

    /// A single plain name term can be checked against the exact overlay
    /// changes without rescanning millions of unaffected base nodes. Anything
    /// more expressive falls back to a conservative full refresh.
    private func revisionRefreshDisposition(
        for changes: SearchIndexChanges?
    ) -> RevisionRefreshDisposition {
        guard let changes else { return .afterQuietPeriod }
        if changes.requiresConservativeRefresh || !changes.subtreeReplacements.isEmpty {
            return .afterQuietPeriod
        }
        guard !changes.exactReplacements.isEmpty else { return .none }

        let rawQuery = options.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let plan = SearchQueryPlan.parse(rawQuery)
        guard options.target == .name,
              options.matchMode == .substring,
              !plan.parseError,
              plan.plainTerms.count == 1,
              plan.explicitContentTerms.isEmpty,
              plan.excludedTerms.isEmpty,
              plan.filters.isEmpty,
              plan.excludedFilters.isEmpty,
              !rawQuery.contains("/"),
              rawQuery.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let query = try? plan.compile(options: options) else {
            return .afterQuietPeriod
        }

        let matchesPinyin = query.matchesPinyin
        for replacement in changes.exactReplacements {
            // For a plain name query, membership depends on the old basename
            // and the replacement node's name, not on its full path. Checking
            // both sides catches removals and renames without materializing a
            // multi-million-result path Set on the main actor.
            let oldName = (replacement.path as NSString).lastPathComponent
            if query.matchesNameFilter(oldName, matchesPinyin: matchesPinyin)
                || replacement.node.map({
                    query.matchesNameFilter($0.name, matchesPinyin: matchesPinyin)
                }) == true {
                return .immediate
            }
        }
        return .none
    }

    private func refreshEventLog() {
        guard displayMode == .events else { return }
        let indexStore = self.indexStore
        Task { [weak self] in
            let events = await indexStore.recentEventLog()
            await MainActor.run {
                guard let self, self.displayMode == .events else { return }
                self.eventEntries = events
            }
        }
    }
}

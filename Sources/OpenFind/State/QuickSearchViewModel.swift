import Foundation
import Observation

@MainActor
@Observable
final class QuickSearchViewModel {
    var query = "" {
        didSet { scheduleSearch() }
    }
    private(set) var results: [QuickSearchItem] = []
    private(set) var selectedIndex = 0
    private(set) var isSearching = false
    var errorMessage: String?
    private(set) var needsFullSearch = false
    private(set) var resultsAreCurrent = false
    private(set) var hasMoreFiles = false
    private(set) var isLoadingMore = false
    private var retainedRowCount = 0

    private let searchApplications: @Sendable (String) async -> [ApplicationSearchResult]
    private let searchSettings: @Sendable (String) async -> [ApplicationSearchResult]
    private let searchFiles: @Sendable (String, Int) async -> QuickSearchFileResponse
    private var fileLimit = 50
    private var searchTask: Task<Void, Never>?
    private var searchGeneration = 0

    init(
        searchApplications: @escaping @Sendable (String) async -> [ApplicationSearchResult] = { query in
            await ApplicationSearchIndex.shared.results(for: query)
        },
        searchSettings: @escaping @Sendable (String) async -> [ApplicationSearchResult] = { query in
            await SystemSettingsSearchIndex.shared.results(for: query)
        },
        searchFiles: @escaping @Sendable (String) async -> QuickSearchFileResponse = { _ in .init() },
        searchFilesWithLimit: (@Sendable (String, Int) async -> QuickSearchFileResponse)? = nil
    ) {
        self.searchApplications = searchApplications
        self.searchSettings = searchSettings
        self.searchFiles = searchFilesWithLimit ?? { query, _ in await searchFiles(query) }
    }

    func prepareForPresentation() {
        searchTask?.cancel()
        query = ""
        results = []
        selectedIndex = 0
        isSearching = false
    }

    func scheduleSearch() {
        fileLimit = 50
        isLoadingMore = false
        startSearch()
    }

    func loadMoreFiles() {
        guard hasMoreFiles, !isLoadingMore, resultsAreCurrent else { return }
        isLoadingMore = true
        fileLimit += 50
        startSearch()
    }

    private func startSearch() {
        searchTask?.cancel()
        searchGeneration &+= 1
        let generation = searchGeneration
        let query = query
        retainedRowCount = min(results.count, 6)
        resultsAreCurrent = false
        hasMoreFiles = false
        errorMessage = nil
        needsFullSearch = false
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            results = []
            retainedRowCount = 0
            selectedIndex = 0
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(35))
            guard !Task.isCancelled, let self else { return }
            async let applicationMatches = self.searchApplications(query)
            async let settingsMatches = self.searchSettings(query)
            let (applications, settings) = await (applicationMatches, settingsMatches)
            guard !Task.isCancelled, generation == self.searchGeneration else { return }
            let immediateItems = applications.map { QuickSearchItem(application: $0) }
                + settings.map { QuickSearchItem(systemSetting: $0) }
            // Keep the previous frame until there is a usable replacement.
            // Old rows cannot be opened for a new query while it is pending.
            if !self.isLoadingMore, !immediateItems.isEmpty { self.publish(immediateItems) }
            repeat {
                let files = await self.searchFiles(query, self.fileLimit)
                guard !Task.isCancelled, generation == self.searchGeneration else { return }
                let applicationURLs = Set(immediateItems.map(\.url))
                let fileItems = files.results.map { QuickSearchItem(file: $0) }
                    .filter { !applicationURLs.contains($0.url) }
                self.publish(immediateItems + fileItems)
                self.needsFullSearch = files.needsFullSearch
                self.hasMoreFiles = files.hasMore
                self.isLoadingMore = false
                self.isSearching = files.isIndexing
                guard files.isIndexing else { return }
                try? await Task.sleep(for: .seconds(1))
            } while !Task.isCancelled && generation == self.searchGeneration
        }
    }

    private func publish(_ items: [QuickSearchItem]) {
        let selectedID = results.indices.contains(selectedIndex) ? results[selectedIndex].id : nil
        results = items
        selectedIndex = items.firstIndex { $0.id == selectedID } ?? 0
        resultsAreCurrent = true
    }

    func moveSelection(by offset: Int) {
        guard resultsAreCurrent, !results.isEmpty else { return }
        if offset > 0, selectedIndex == results.count - 1, hasMoreFiles {
            loadMoreFiles()
            return
        }
        selectedIndex = (selectedIndex + offset + results.count) % results.count
    }

    func selectResult(at index: Int) {
        guard resultsAreCurrent, results.indices.contains(index) else { return }
        selectedIndex = index
    }

    var selectedResult: QuickSearchItem? {
        guard resultsAreCurrent, results.indices.contains(selectedIndex) else { return nil }
        return results[selectedIndex]
    }

    var statusMessage: String? {
        if let errorMessage { return errorMessage }
        if needsFullSearch { return L("Quick Search Advanced Hint") }
        guard !query.isEmpty, results.isEmpty else { return nil }
        return isSearching ? L("Quick Search Loading") : L("Quick Search No Results")
    }

    var presentationHeight: CGFloat {
        let count = isSearching ? max(retainedRowCount, min(results.count, 6)) : min(results.count, 6)
        let rows = count == 0 ? 0 : 16 + CGFloat(count) * 56
        return 118 + rows + (statusMessage == nil ? 0 : 40)
    }

    func cancel() {
        searchGeneration &+= 1
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
        isLoadingMore = false
    }
}

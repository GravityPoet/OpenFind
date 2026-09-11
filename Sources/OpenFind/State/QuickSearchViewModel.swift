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

    private let searchApplications: @Sendable (String) async -> [ApplicationSearchResult]
    private let searchFiles: @Sendable (String) async -> QuickSearchFileResponse
    private var searchTask: Task<Void, Never>?
    private var searchGeneration = 0

    init(
        searchApplications: @escaping @Sendable (String) async -> [ApplicationSearchResult] = { query in
            await ApplicationSearchIndex.shared.results(for: query)
        },
        searchFiles: @escaping @Sendable (String) async -> QuickSearchFileResponse = { _ in .init() }
    ) {
        self.searchApplications = searchApplications
        self.searchFiles = searchFiles
    }

    func prepareForPresentation() {
        searchTask?.cancel()
        query = ""
        results = []
        selectedIndex = 0
        isSearching = false
    }

    func scheduleSearch() {
        searchTask?.cancel()
        searchGeneration &+= 1
        let generation = searchGeneration
        let query = query
        results = []
        selectedIndex = 0
        errorMessage = nil
        needsFullSearch = false
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(35))
            guard !Task.isCancelled, let self else { return }
            let applications = await self.searchApplications(query)
            guard !Task.isCancelled, generation == self.searchGeneration else { return }
            let appItems = applications.prefix(6).map { QuickSearchItem(application: $0) }
            self.results = appItems
            self.selectedIndex = 0
            repeat {
                let files = await self.searchFiles(query)
                guard !Task.isCancelled, generation == self.searchGeneration else { return }
                let applicationURLs = Set(appItems.map(\.url))
                let fileItems = files.results.map { QuickSearchItem(file: $0) }
                    .filter { !applicationURLs.contains($0.url) }
                let selected = self.selectedResult?.id
                self.results = Array((appItems + fileItems).prefix(9))
                self.selectedIndex = self.results.firstIndex(where: { $0.id == selected }) ?? 0
                self.needsFullSearch = files.needsFullSearch
                self.isSearching = files.isIndexing
                guard files.isIndexing else { return }
                try? await Task.sleep(for: .seconds(1))
            } while !Task.isCancelled && generation == self.searchGeneration
        }
    }

    func moveSelection(by offset: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = (selectedIndex + offset + results.count) % results.count
    }

    func selectResult(at index: Int) {
        guard results.indices.contains(index) else { return }
        selectedIndex = index
    }

    var selectedResult: QuickSearchItem? {
        guard results.indices.contains(selectedIndex) else { return nil }
        return results[selectedIndex]
    }

    var statusMessage: String? {
        if let errorMessage { return errorMessage }
        if needsFullSearch { return L("Quick Search Advanced Hint") }
        guard !query.isEmpty, results.isEmpty else { return nil }
        return isSearching ? L("Quick Search Loading") : L("Quick Search No Results")
    }

    var presentationHeight: CGFloat {
        let rows = results.isEmpty ? 0 : 16 + CGFloat(min(results.count, 6)) * 56
        return 118 + rows + (statusMessage == nil ? 0 : 40)
    }

    func cancel() {
        searchGeneration &+= 1
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
    }
}

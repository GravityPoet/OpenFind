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
    private(set) var hasExplicitSelection = false
    private(set) var isSearching = false
    var errorMessage: String?
    var isSendingCommand = false
    private(set) var needsFullSearch = false
    private(set) var resultsAreCurrent = false
    private(set) var hasMoreFiles = false
    private(set) var isLoadingMore = false
    private(set) var commandMode: QuickSearchMode = .combined
    private var retainedRowCount = 0
    private(set) var recentApplication: ApplicationSearchResult?
    private(set) var contactDetail: QuickContact?
    private var sourceMessage: String?

    private let searchApplications: @Sendable (String) async -> [ApplicationSearchResult]
    private let searchSettings: @Sendable (String) async -> [ApplicationSearchResult]
    private let searchFiles: @Sendable (String, Int) async -> QuickSearchFileResponse
    private let searchSource: @Sendable (QuickSearchCommand, Int, ApplicationSearchResult?) async -> QuickSearchSourceResponse
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
        searchFilesWithLimit: (@Sendable (String, Int) async -> QuickSearchFileResponse)? = nil,
        searchSource: @escaping @Sendable (QuickSearchCommand, Int, ApplicationSearchResult?) async -> QuickSearchSourceResponse = { command, limit, application in
            await QuickSearchSources.results(command, limit: limit, application: application)
        }
    ) {
        self.searchApplications = searchApplications
        self.searchSettings = searchSettings
        self.searchFiles = searchFilesWithLimit ?? { query, _ in await searchFiles(query) }
        self.searchSource = searchSource
    }

    func prepareForPresentation() {
        searchTask?.cancel()
        query = ""
        results = []
        selectedIndex = 0
        isSearching = false
        commandMode = .combined
    }

    func scheduleSearch() {
        hasExplicitSelection = false
        contactDetail = nil
        if QuickSearchCommand.parse(query).mode != .recent { recentApplication = nil }
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
        let command = QuickSearchCommand.parse(query)
        commandMode = command.mode
        retainedRowCount = min(results.count, 6)
        resultsAreCurrent = false
        hasMoreFiles = false
        errorMessage = nil
        sourceMessage = nil
        needsFullSearch = false
        guard !command.term.isEmpty || command.mode != .combined else {
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

            if command.mode == .content || command.mode == .tags {
                self.publish(command.term.isEmpty ? [] : [self.fullSearchItem(for: command)])
                self.isSearching = false
                return
            }
            if command.mode == .calculator {
                let expression = command.term
                guard let value = QuickCalculator.evaluate(expression) else {
                    self.publish([])
                    self.isSearching = false
                    return
                }
                self.publish([.init(url: URL(string: "openfind-action:/calculator")!,
                                   name: "\(expression) = \(value)", location: L("Calculator"),
                                   kind: .command, action: .copyText(value))])
                self.isSearching = false
                return
            }
            if command.mode == .dictionary {
                let word = command.term
                guard !word.isEmpty else { self.publish([]); self.isSearching = false; return }
                let definition = await Task.detached { QuickDictionary.definition(for: word) }.value
                guard !Task.isCancelled, generation == self.searchGeneration else { return }
                let encodedWord = word.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
                self.publish([.init(url: URL(string: "dict:///" + encodedWord)!,
                                   name: word, location: definition ?? L("Dictionary"), kind: .command)])
                self.isSearching = false
                return
            }
            if command.mode == .system {
                self.publish(QuickSystemCommands.results(for: command.term, limit: self.fileLimit))
                self.isSearching = false
                return
            }
            if command.mode == .terminal {
                if let terminal = TerminalCommand(input: command.term) {
                    let encoded = terminal.text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
                    self.publish([.init(url: URL(string: "openfind-action:/terminal?command=\(encoded)")!,
                                       name: String(format: L("Run in Terminal Format"), terminal.text),
                                       location: L("Terminal"), kind: .command, action: .terminal(terminal.text))])
                } else {
                    self.publish([])
                    if !command.term.trimmingCharacters(in: .whitespaces).isEmpty {
                        self.sourceMessage = L("Terminal Invalid Command")
                    }
                }
                self.isSearching = false
                return
            }
            let pathCommand = QuickSearchCommand.parse(command.term)
            if command.mode == .path || ([.open, .find].contains(command.mode) && pathCommand.mode == .path) {
                var response = await self.searchSource(pathCommand, self.fileLimit, nil)
                guard !Task.isCancelled, generation == self.searchGeneration else { return }
                if command.mode == .find {
                    response.items = response.items.map { .init(url: $0.url, name: $0.name, location: $0.location, kind: $0.kind, action: .reveal) }
                }
                self.publishSource(response)
                return
            }
            if [.bookmarks, .contacts, .web, .recent].contains(command.mode) {
                async let response = self.searchSource(command, self.fileLimit, self.recentApplication)
                var appItems: [QuickSearchItem] = []
                if command.mode == .recent, self.recentApplication == nil, !command.term.isEmpty {
                    let apps = await self.searchApplications(command.term)
                    appItems = apps.map { .init(application: $0, action: .recentDocuments($0)) }
                }
                var source = await response
                guard !Task.isCancelled, generation == self.searchGeneration else { return }
                source.items = appItems + source.items
                if !appItems.isEmpty { source.message = nil }
                self.publishSource(source)
                return
            }

            await self.searchCombined(command, generation: generation)
        }
    }

    private enum SourceUpdate: Sendable {
        case applications([ApplicationSearchResult])
        case settings([ApplicationSearchResult])
        case extras(QuickSearchSourceResponse)
        case files(QuickSearchFileResponse)
    }

    private func searchCombined(_ command: QuickSearchCommand, generation: Int) async {
        let apps = searchApplications, settings = searchSettings, source = searchSource, files = searchFiles
        let limit = fileLimit
        await withTaskGroup(of: SourceUpdate.self) { group in
            if command.mode != .settings {
                group.addTask { .applications(await apps(command.term)) }
            }
            if [.combined, .settings].contains(command.mode) {
                group.addTask { .settings(await settings(command.term)) }
            }
            if command.mode == .combined {
                group.addTask { .extras(await source(command, limit, nil)) }
            }
            if [.combined, .open, .find].contains(command.mode), !command.term.isEmpty {
                group.addTask { .files(await files(command.term, limit)) }
            }
            var appItems: [QuickSearchItem] = []
            var settingItems: [QuickSearchItem] = []
            var extra = QuickSearchSourceResponse()
            var fileResponse = QuickSearchFileResponse()
            var fileItems: [QuickSearchItem] = []
            while let update = await group.next() {
                guard !Task.isCancelled, generation == searchGeneration else { group.cancelAll(); return }
                switch update {
                case .applications(let matches):
                    appItems = matches.map { .init(application: $0, action: command.mode == .find ? .reveal : .open) }
                case .settings(let matches): settingItems = matches.map { .init(systemSetting: $0) }
                case .extras(let response): extra = response
                case .files(let response):
                    fileResponse = response
                    fileItems = response.results.map { .init(file: $0, action: command.mode == .find ? .reveal : .open) }
                    if response.isIndexing {
                        group.addTask {
                            try? await Task.sleep(for: .seconds(1))
                            guard !Task.isCancelled else { return .files(.init()) }
                            return .files(await files(command.term, limit))
                        }
                    }
                }
                var items = appItems + settingItems + extra.items + fileItems
                if command.mode == .combined, let value = QuickCalculator.evaluate(command.term),
                   command.term.contains(where: { "+-*/%".contains($0) }) {
                    items.insert(.init(url: URL(string: "openfind-action:/calculator")!, name: value,
                                       location: command.term, kind: .command, action: .copyText(value)), at: 0)
                }
                if group.isEmpty, items.isEmpty, command.mode == .combined, !fileResponse.needsFullSearch {
                    items = WebSearchIndex.results(for: command.term)
                }
                // Each source can replace stale rows as soon as it is ready.
                // Pagination retains the old page until the larger one arrives.
                if (!isLoadingMore && !items.isEmpty) || group.isEmpty { publish(items) }
                needsFullSearch = fileResponse.needsFullSearch
                hasMoreFiles = fileResponse.hasMore || extra.hasMore
                isSearching = !group.isEmpty
                if group.isEmpty { isLoadingMore = false }
            }
        }
    }

    private func publishSource(_ source: QuickSearchSourceResponse) {
        publish(source.items)
        hasMoreFiles = source.hasMore
        sourceMessage = source.message
        isLoadingMore = false
        isSearching = false
    }

    func showRecentDocuments(for application: ApplicationSearchResult) {
        recentApplication = application
        query = "recent "
    }

    func selectMode(_ mode: QuickSearchMode) {
        recentApplication = nil
        let term = QuickSearchCommand.parse(query).term
        query = mode == .path ? "~/" : mode.prefix + term
    }

    @discardableResult func navigateIntoSelection() -> Bool {
        guard let item = selectedResult, item.isDirectory else { return false }
        query = item.url.path + "/"
        return true
    }

    @discardableResult func navigateBack() -> Bool {
        if contactDetail != nil {
            contactDetail = nil
            return true
        }
        if recentApplication != nil {
            recentApplication = nil
            query = "recent "
            return true
        }
        guard commandMode == .path else { return false }
        let parent = QuickPathSearch.parent(of: QuickSearchCommand.parse(query).term)
        guard parent != query else { return false }
        query = parent
        return true
    }

    func showContact(_ contact: QuickContact) {
        cancel()
        contactDetail = contact
    }

    private func publish(_ items: [QuickSearchItem]) {
        let selectedID = results.indices.contains(selectedIndex) ? results[selectedIndex].id : nil
        var seen = Set<URL>()
        results = items.filter { seen.insert($0.id).inserted }
        if !results.contains(where: { $0.id == selectedID }) { hasExplicitSelection = false }
        selectedIndex = results.firstIndex { $0.id == selectedID } ?? 0
        resultsAreCurrent = true
    }

    private func fullSearchItem(for command: QuickSearchCommand) -> QuickSearchItem {
        let title: String
        switch command.mode {
        case .content: title = L("Search File Contents")
        case .tags: title = L("Search Finder Tags")
        default: title = L("Full Search")
        }
        let query = command.fullSearchQuery
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? query
        return QuickSearchItem(url: URL(string: "openfind-action://full-search/\(encoded)")!,
                               name: "\(title)：\(command.term)", location: L("Full Search"),
                               kind: .command, action: .fullSearch(query))
    }

    func moveSelection(by offset: Int) {
        guard contactDetail == nil, resultsAreCurrent, !results.isEmpty else { return }
        hasExplicitSelection = true
        if offset > 0, selectedIndex == results.count - 1, hasMoreFiles {
            loadMoreFiles()
            return
        }
        selectedIndex = (selectedIndex + offset + results.count) % results.count
    }

    func selectResult(at index: Int) {
        guard resultsAreCurrent, results.indices.contains(index) else { return }
        selectedIndex = index
        hasExplicitSelection = true
    }

    var selectedResult: QuickSearchItem? {
        guard contactDetail == nil, resultsAreCurrent, results.indices.contains(selectedIndex) else { return nil }
        return results[selectedIndex]
    }

    var statusMessage: String? {
        if contactDetail != nil { return nil }
        if isSendingCommand { return L("Terminal Sending") }
        if let errorMessage { return errorMessage }
        if let sourceMessage { return sourceMessage }
        if commandMode != .combined, results.isEmpty, !isSearching {
            return QuickSearchCommand(mode: commandMode, term: query).localizedHint
        }
        if needsFullSearch { return L("Quick Search Advanced Hint") }
        guard !query.isEmpty, results.isEmpty else { return nil }
        return isSearching ? L("Quick Search Loading") : L("Quick Search No Results")
    }

    var presentationHeight: CGFloat {
        if contactDetail != nil { return 398 }
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

    /// Releases the result rows once the palette is no longer visible. The
    /// application and settings indexes remain shared and warm, so the next
    /// presentation stays fast without retaining a stale file-result buffer.
    func releaseTransientResults() {
        cancel()
        results.removeAll(keepingCapacity: false)
        selectedIndex = 0
        retainedRowCount = 0
        hasExplicitSelection = false
        hasMoreFiles = false
        needsFullSearch = false
        resultsAreCurrent = false
        commandMode = .combined
        recentApplication = nil
        contactDetail = nil
        sourceMessage = nil
        errorMessage = nil
    }
}

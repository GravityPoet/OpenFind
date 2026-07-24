import SwiftUI

enum SearchFocusTarget: Hashable {
    case query
    case results
}

struct ContentView: View {
    @Bindable var viewModel: SearchViewModel
    let quickLook: QuickLookController
    let onShowClipboardHistory: () -> Void
    let onShowMenuBar: () -> Void
    let onShowSettings: () -> Void
    let firstRunCapabilities: () -> [FirstRunCapability]
    @FocusState private var focusedTarget: SearchFocusTarget?
    @State private var selection = Set<SearchResult.ID>()
    @State private var isFirstRunGuidePresented = false
    @AppStorage(FirstRunGuideStore.completionKey)
    private var hasCompletedFirstRunGuide = false
    /// Empty means preserve engine relevance order. Once the user selects a
    /// table column, keep that explicit order during and after every refresh.
    @State private var sortOrder: [KeyPathComparator<SearchResult>] = []
    @State private var eventSelection = Set<FileSystemEventLogEntry.ID>()
    @State private var eventSortOrder = [KeyPathComparator<FileSystemEventLogEntry>(\.receivedAt, order: .reverse)]

    var body: some View {
        VStack(spacing: 0) {
            SearchHeader(
                viewModel: viewModel,
                focusedTarget: $focusedTarget,
                onMoveToResults: selectFirstResult
            )

            Divider()

            FilterBar(viewModel: viewModel)

            Divider()

            resultsView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(NSColor.controlBackgroundColor))

            Divider()

            StatusBar(viewModel: viewModel)
        }
        .frame(minWidth: 800, minHeight: 500)
        .ignoresSafeArea()
        .openFindInterfaceSizing()
        .sheet(
            isPresented: $isFirstRunGuidePresented,
            onDismiss: completeFirstRunGuide
        ) {
            FirstRunGuideView(
                capabilities: firstRunCapabilities(),
                onStartSearching: {
                    isFirstRunGuidePresented = false
                    focusedTarget = .query
                },
                onOpenSettings: {
                    isFirstRunGuidePresented = false
                    onShowSettings()
                },
                onDismiss: {
                    isFirstRunGuidePresented = false
                }
            )
        }
        .onAppear {
            if !hasCompletedFirstRunGuide {
                isFirstRunGuidePresented = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openFindShowWelcome)) { _ in
            isFirstRunGuidePresented = true
        }
        .onChange(of: selection) {
            quickLook.update(items: selectedURLs)
        }
        .onChange(of: viewModel.results) {
            selection.formIntersection(Set(viewModel.results.map(\.id)))
            quickLook.update(items: selectedURLs)
        }
        .onChange(of: viewModel.displayMode) {
            if viewModel.displayMode == .events {
                quickLook.close()
            }
        }
        .onDisappear {
            quickLook.close()
        }
    }

    private func completeFirstRunGuide() {
        hasCompletedFirstRunGuide = true
        FirstRunGuideStore.markCompleted()
        focusedTarget = .query
    }

    @ViewBuilder
    private var resultsView: some View {
        if viewModel.displayMode == .events {
            eventsView
        } else if viewModel.scopes.isEmpty {
            ContentUnavailableView(
                L("No Search Scopes"),
                systemImage: "folder.badge.plus",
                description: Text(L("Add a folder to search in"))
            )
        } else if viewModel.options.query.trimmingCharacters(in: .whitespaces).isEmpty {
            readinessView
        } else if viewModel.isBroadContentSearchBlocked {
            broadContentSearchWarning
        } else if let errorMessage = viewModel.searchErrorMessage {
            searchErrorView(errorMessage)
        } else if viewModel.shouldShowSearchIncompleteState {
            indexingInProgressView
        } else if viewModel.results.isEmpty && !viewModel.isSearching {
            noResultsView
        } else {
            ResultsTable(
                results: sortedResults,
                metadataAvailable: !viewModel.indexStats.isMetadataEnriching,
                selection: $selection,
                sortOrder: $sortOrder,
                focusedTarget: $focusedTarget,
                onQuickLook: { quickLook.toggle(items: $0) },
                onMoveToTrash: { viewModel.moveResultsToTrash($0) }
            )
        }
    }

    @ViewBuilder
    private var eventsView: some View {
        VStack(spacing: 0) {
            eventExplanationBanner

            Divider()

            eventContentView
        }
    }

    @ViewBuilder
    private var eventContentView: some View {
        if viewModel.eventEntries.isEmpty {
            ContentUnavailableView(
                L("No File Events Yet"),
                systemImage: "waveform.path.ecg",
                description: Text(L("OpenFind will show file-system changes here after the index starts watching your selected scopes."))
            )
        } else if viewModel.filteredEventEntries.isEmpty {
            ContentUnavailableView(
                String(format: L("No Events for %@"), trimmedQuery),
                systemImage: "line.3.horizontal.decrease.circle",
                description: Text(L("Try a filename, folder path, or event type such as Renamed or Modified."))
            )
        } else {
            EventsTable(
                events: sortedEvents,
                selection: $eventSelection,
                sortOrder: $eventSortOrder
            )
        }
    }

    private var eventExplanationBanner: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)

            Text(L("This page shows file-system changes observed by macOS. It does not mean OpenFind modified these files."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color(NSColor.controlBackgroundColor))
    }

    @ViewBuilder
    private var readinessView: some View {
        if viewModel.shouldShowReadinessGuidance {
            ContentUnavailableView {
                Label(readinessTitle, systemImage: "magnifyingglass")
            } description: {
                Text(readinessDescription)
            } actions: {
                VStack(spacing: 12) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 14) {
                            readinessActionContent
                        }

                        VStack(spacing: 10) {
                            readinessActionContent
                        }
                    }

                    productQuickActions
                }
            }
        } else {
            ContentUnavailableView {
                Label(L("Start searching by typing a query"), systemImage: "magnifyingglass")
            } description: {
                Text(L("Names match file names by default. Use / or path: to search paths."))
            } actions: {
                productQuickActions
            }
        }
    }

    @ViewBuilder
    private var readinessActionContent: some View {
        if viewModel.indexStats.isIndexing {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 14, height: 14)
                Text(String(
                    format: viewModel.indexStats.isMetadataEnriching
                        ? L("Indexed %lld items; names and paths are ready")
                        : viewModel.indexStats.loadedFromDisk
                            ? L("Loaded %lld indexed items; search is ready")
                            : L("Indexing %lld items so far"),
                    Int64(viewModel.indexStats.indexedItems)
                ))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .fixedSize(horizontal: true, vertical: false)
        }

        if !viewModel.hasFullDiskAccess {
            Button {
                FileActions.openSystemPrivacySettings()
            } label: {
                Label(L("Enable Full Disk Access"), systemImage: "lock.shield")
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var indexingInProgressView: some View {
        ContentUnavailableView {
            Label(indexingInProgressTitle, systemImage: "doc.text.magnifyingglass")
        } description: {
            Text(indexingInProgressDescription)
        } actions: {
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text(String(
                    format: viewModel.indexStats.loadedFromDisk
                        ? L("Loaded %lld indexed items; search is ready")
                        : L("Indexing %lld items so far"),
                    Int64(viewModel.indexStats.indexedItems)
                ))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var indexingInProgressTitle: String {
        viewModel.indexStats.loadedFromDisk
            ? L("Updating recent file changes")
            : L("Indexing is still in progress")
    }

    private var indexingInProgressDescription: String {
        viewModel.indexStats.loadedFromDisk
            ? L("Your saved index is searchable now. New or renamed files will appear as OpenFind finishes syncing.")
            : L("Results are still incomplete while OpenFind builds the local index. If nothing appears yet, keep typing or wait for indexing to finish.")
    }

    private func searchErrorView(_ message: String) -> some View {
        ContentUnavailableView {
            Label(message, systemImage: "exclamationmark.triangle")
        } description: {
            Text(L("Adjust the query or switch to a simpler match mode."))
        } actions: {
            Button {
                viewModel.options.matchMode = .substring
                viewModel.scheduleSearch(delay: .zero)
            } label: {
                Label(L("Use Contains"), systemImage: "text.magnifyingglass")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var broadContentSearchWarning: some View {
        ContentUnavailableView {
            Label(
                L("Content Search Needs a Smaller Scope"),
                systemImage: "exclamationmark.triangle"
            )
        } description: {
            Text(L("Content search over your home folder still reads candidate file contents on demand and can take a very long time. Narrow the scope, or use name search for quick file lookup."))
        } actions: {
            HStack {
                Button {
                    viewModel.options.target = .name
                    viewModel.scheduleSearch(delay: .zero)
                } label: {
                    Label(L("Search Names Only"), systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    viewModel.startBroadContentSearchAnyway()
                } label: {
                    Label(L("Search Contents Anyway"), systemImage: "play.circle")
                }
            }
        }
    }

    private var noResultsView: some View {
        ContentUnavailableView {
            Label(
                String(format: L("No Results for %@"), trimmedQuery),
                systemImage: "magnifyingglass.circle"
            )
        } description: {
            Text(noResultsDescription)
        } actions: {
            HStack {
                if viewModel.options.target != .both {
                    Button {
                        viewModel.options.target = .both
                        viewModel.scheduleSearch(delay: .zero)
                    } label: {
                        Label(L("Search Names and Contents"), systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.borderedProminent)
                }

                Button {
                    viewModel.options.query = ""
                    viewModel.scheduleSearch(delay: .zero)
                } label: {
                    Label(L("Clear Search"), systemImage: "xmark.circle")
                }
            }
        }
    }

    private var trimmedQuery: String {
        viewModel.options.query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var noResultsDescription: String {
        switch viewModel.options.target {
        case .name:
            return L("Only file names were searched. Check spelling, or search names and contents.")
        case .content:
            return L("Only file contents were searched. Check spelling, or search names and contents.")
        case .both:
            return L("Check spelling, try a broader term, or adjust search options.")
        }
    }

    private var readinessDescription: String {
        if viewModel.indexStats.isMetadataEnriching {
            return L("Names and paths are ready to search while OpenFind enriches file details in the background.")
        }
        if !viewModel.hasFullDiskAccess && viewModel.indexStats.isIndexing {
            if viewModel.options.deepIndex {
                return L("OpenFind is indexing every location macOS currently allows. Enable Full Disk Access to include protected folders that remain unavailable.")
            }
            return L("OpenFind is building its local index. Protected folders are skipped until Full Disk Access is enabled, which avoids blocking macOS permission popups.")
        }
        if !viewModel.hasFullDiskAccess {
            if viewModel.options.deepIndex {
                return L("OpenFind includes every folder macOS currently allows. Enable Full Disk Access to search protected locations that remain unavailable.")
            }
            return L("Enable Full Disk Access to include Desktop, Documents, Downloads, Music, Movies, Pictures, Mail, and external volumes. Until then, OpenFind skips those folders instead of showing blocking macOS permission popups.")
        }
        if viewModel.indexStats.loadedFromDisk && viewModel.indexStats.isIndexing {
            return L("The saved index is ready to search while OpenFind synchronizes file changes since the last exit.")
        }
        return L("OpenFind is building its local index. Search results will stream in as files are scanned.")
    }

    private var readinessTitle: String {
        if viewModel.indexStats.isMetadataEnriching
            || (viewModel.indexStats.loadedFromDisk && viewModel.indexStats.indexedItems > 0) {
            return L("OpenFind is ready to search")
        }
        return L("Preparing OpenFind")
    }

    private var productQuickActions: some View {
        ProductQuickActions(
            onShowClipboardHistory: onShowClipboardHistory,
            onShowMenuBar: onShowMenuBar,
            onShowSettings: onShowSettings
        )
    }

    private var sortedResults: [SearchResult] {
        guard !sortOrder.isEmpty else { return viewModel.results }
        return viewModel.results.sorted(using: sortOrder)
    }

    private var sortedEvents: [FileSystemEventLogEntry] {
        viewModel.filteredEventEntries.sorted(using: eventSortOrder)
    }

    private var selectedURLs: [URL] {
        sortedResults.compactMap { selection.contains($0.id) ? $0.url : nil }
    }

    private func selectFirstResult() -> Bool {
        guard viewModel.displayMode == .files, let first = sortedResults.first else { return false }
        selection = [first.id]
        return true
    }
}

import SwiftUI

struct ContentView: View {
    @Bindable var viewModel: SearchViewModel
    @State private var selection = Set<SearchResult.ID>()
    @State private var sortOrder = [KeyPathComparator<SearchResult>(\.name)]

    var body: some View {
        VStack(spacing: 0) {
            SearchHeader(viewModel: viewModel)

            Divider()

            FilterBar(viewModel: viewModel)

            Divider()

            resultsView

            Divider()

            StatusBar(viewModel: viewModel)
        }
        .frame(minWidth: 800, minHeight: 500)
    }

    @ViewBuilder
    private var resultsView: some View {
        if viewModel.scopes.isEmpty {
            ContentUnavailableView(
                L("No Search Scopes"),
                systemImage: "folder.badge.plus",
                description: Text(L("Add a folder to search in"))
            )
        } else if viewModel.options.query.trimmingCharacters(in: .whitespaces).isEmpty {
            ContentUnavailableView(
                L("Start searching by typing a query"),
                systemImage: "magnifyingglass"
            )
        } else if viewModel.isBroadContentSearchBlocked {
            broadContentSearchWarning
        } else if viewModel.results.isEmpty && !viewModel.isSearching {
            noResultsView
        } else {
            ResultsTable(
                results: sortedResults,
                selection: $selection,
                sortOrder: $sortOrder
            )
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

    private var sortedResults: [SearchResult] {
        if viewModel.isSearching {
            return viewModel.results
        } else {
            return viewModel.results.sorted(using: sortOrder)
        }
    }
}

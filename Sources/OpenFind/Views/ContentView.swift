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
        } else if viewModel.results.isEmpty && !viewModel.isSearching {
            ContentUnavailableView(
                L("No Results Found"),
                systemImage: "magnifyingglass.circle"
            )
        } else {
            ResultsTable(
                results: sortedResults,
                selection: $selection,
                sortOrder: $sortOrder
            )
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

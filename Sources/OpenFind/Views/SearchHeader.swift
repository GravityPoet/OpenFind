import SwiftUI

struct SearchHeader: View {
    @Bindable var viewModel: SearchViewModel
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField(L("Search..."), text: $viewModel.options.query)
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .onSubmit {
                        viewModel.startSearch()
                    }
                    .onChange(of: viewModel.options.query) {
                        viewModel.scheduleSearch()
                    }

                if !viewModel.options.query.isEmpty {
                    Button {
                        viewModel.options.query = ""
                        viewModel.scheduleSearch(delay: .zero)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                if viewModel.isSearching {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(10)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isFocused ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: isFocused ? 1.2 : 1)
            )
            .animation(.easeOut(duration: 0.15), value: isFocused)

            if !viewModel.recentSearches.isEmpty {
                Menu {
                    ForEach(viewModel.recentSearches, id: \.self) { search in
                        Button(search) {
                            viewModel.applyRecentSearch(search)
                        }
                    }
                } label: {
                    Label("", systemImage: "clock")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
            }
        }
        .padding(.horizontal)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .onAppear {
            isFocused = true
        }
    }
}

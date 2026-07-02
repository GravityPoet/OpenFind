import SwiftUI

struct SearchHeader: View {
    @Bindable var viewModel: SearchViewModel
    @FocusState private var isFocused: Bool

    var body: some View {
        GlassEffectContainer {
            HStack(spacing: 12) {
                // Padding for traffic light window control buttons in hiddenTitleBar style
                Spacer()
                    .frame(width: 80)

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
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .glassEffect(in: .capsule)
                .overlay(
                    Capsule()
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
                        Image(systemName: "clock")
                            .foregroundStyle(.primary)
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 32, height: 32)
                    .glassEffect(in: .circle)
                    .overlay(
                        Circle()
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
                }
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

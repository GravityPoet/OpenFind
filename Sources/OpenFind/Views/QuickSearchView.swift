import SwiftUI

struct QuickSearchView: View {
    @Bindable var viewModel: QuickSearchViewModel
    let scale: CGFloat
    let onOpen: (QuickSearchItem) -> Void
    let onRecentDocuments: (QuickSearchItem) -> Void
    let onQuickLook: (QuickSearchItem) -> Void
    let onFullSearch: () -> Void
    let onResize: (CGFloat) -> Void
    let onInputReady: (NSTextField) -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            searchField
            if let contact = viewModel.contactDetail {
                QuickContactDetailView(contact: contact, scale: scale, onBack: { _ = viewModel.navigateBack() })
            } else if !viewModel.results.isEmpty { resultsList }
            if let status = viewModel.statusMessage {
                Text(status)
                    .font(.system(size: 12 * scale))
                    .lineLimit(2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20 * scale)
                    .frame(height: 40 * scale)
            }
            Spacer(minLength: 0)
            Divider().opacity(0.4).padding(.horizontal, 12 * scale)
            footer
        }
        .padding(8 * scale)
        .disabled(viewModel.isSendingCommand)
        .background { glassSurface }
        .clipShape(RoundedRectangle(cornerRadius: 24 * scale, style: .continuous))
        .onChange(of: viewModel.presentationHeight) { _, value in onResize(value * scale) }
    }

    private var searchField: some View {
        HStack(spacing: 14 * scale) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 23 * scale, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            if viewModel.recentApplication != nil || viewModel.commandMode == .path {
                Button { _ = viewModel.navigateBack() } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.plain).help(L("Go Back"))
                    .accessibilityIdentifier("OpenFind.quickSearch.back")
            }
            QuickSearchInput(text: $viewModel.query, scale: scale, onReady: onInputReady)
                .frame(height: 34 * scale)
            if viewModel.isSearching || viewModel.isSendingCommand {
                ProgressView().controlSize(.small).accessibilityLabel(L("Searching..."))
            }
            if !viewModel.query.isEmpty {
                Button { viewModel.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        .frame(width: 28 * scale, height: 28 * scale)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("Clear Search"))
            }
        }
        .padding(.horizontal, 18 * scale)
        .frame(height: 64 * scale)
    }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(viewModel.results.enumerated()), id: \.element.id) { index, result in
                        QuickSearchRow(
                            item: result, index: index, isSelected: index == viewModel.selectedIndex,
                            scale: scale, onOpen: { onOpen(result) },
                            onRecentDocuments: { onRecentDocuments(result) },
                            onQuickLook: { onQuickLook(result) }
                        )
                        .id(result.id)
                        .disabled(!viewModel.resultsAreCurrent)
                    }
                    if viewModel.hasMoreFiles {
                        Button(L("Load More Results")) { viewModel.loadMoreFiles() }
                            .disabled(viewModel.isLoadingMore)
                            .padding(12 * scale)
                            .accessibilityIdentifier("OpenFind.quickSearch.loadMore")
                    }
                }
                .padding(.horizontal, 4 * scale)
                .padding(.vertical, 8 * scale)
            }
            .onChange(of: viewModel.selectedResult?.id) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8 * scale) {
            Menu {
                ForEach(QuickSearchMode.allCases, id: \.self) { mode in
                    Button {
                        viewModel.selectMode(mode)
                    } label: {
                        Text(LD(mode.titleKey) + (mode.prefix.isEmpty ? "" : "   " + mode.prefix))
                    }
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(L("Search Modes"))
            .accessibilityLabel(L("Search Modes"))
            .accessibilityIdentifier("OpenFind.quickSearch.modes")
            Text(viewModel.recentApplication.map { L("Recent Documents") + " · " + $0.name }
                 ?? (viewModel.query.isEmpty ? L("Quick Search Scope")
                     : LD(QuickSearchCommand.parse(viewModel.query).hintKey)))
                .lineLimit(1)
                .foregroundStyle(.secondary)
                .help(viewModel.recentApplication.map { L("Recent Documents") + " · " + $0.name }
                      ?? LD(QuickSearchCommand.parse(viewModel.query).hintKey))
            Spacer(minLength: 4)
            Button(action: onFullSearch) {
                HStack(spacing: 6 * scale) {
                    Text(L("Full Search"))
                    Text("⌥↩").font(.system(size: 11 * scale, design: .monospaced))
                }
                .padding(.horizontal, 9 * scale)
                .padding(.vertical, 5 * scale)
                .background(.primary.opacity(0.04), in: Capsule())
            }
            .buttonStyle(.plain)
            .help(L("Quick Search Full Help"))
            .accessibilityIdentifier("OpenFind.quickSearch.fullSearch")
            .disabled(viewModel.commandMode == .terminal)
        }
        .font(.system(size: 11 * scale))
        .padding(.horizontal, 14 * scale)
        .frame(height: 37 * scale)
    }

    @ViewBuilder private var glassSurface: some View {
        let shape = RoundedRectangle(cornerRadius: 24 * scale, style: .continuous)
        if reduceTransparency {
            shape.fill(Color(nsColor: .windowBackgroundColor))
        } else {
            Color.clear
                .openFindGlassRoundedRectangle(cornerRadius: 24 * scale)
                .overlay {
                    if contrast != .increased {
                        LinearGradient(
                            colors: [.white.opacity(colorScheme == .dark ? 0.03 : 0.10),
                                     Color.accentColor.opacity(0.035), .clear],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                        .clipShape(shape).allowsHitTesting(false)
                    }
                }
        }
    }
}

import SwiftUI

struct ClipboardHistoryHeader: View {
    @Bindable var store: ClipboardHistoryStore
    @FocusState.Binding var searchFocused: Bool
    @Binding var isActionPanelPresented: Bool
    let onPerformAction: (ClipboardPanelAction) -> Void
    let onPerformContentAction: (ClipboardContentActionDescriptor) -> Void
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        HStack(spacing: 8) {
            searchControls

            Button {
                isActionPanelPresented.toggle()
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(.regularMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help(L("Clipboard History Actions"))
            .accessibilityLabel(Text(L("Clipboard Actions")))
            .accessibilityIdentifier("clipboard.actions")
            .popover(isPresented: $isActionPanelPresented, arrowEdge: .top) {
                ClipboardActionPanel(
                    itemActions: actionContext.itemActions,
                    contentActions: contentActions,
                    historyActions: ClipboardPanelActionContext.historyActions,
                    onPerform: onPerformAction,
                    onPerformContentAction: onPerformContentAction,
                    onDismiss: { isActionPanelPresented = false }
                )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }

    private var contentActions: [ClipboardContentActionDescriptor] {
        guard actionContext.selectedEntries.count == 1,
              let entry = actionContext.entry else { return [] }
        return store.availableContentActions(for: entry)
    }

    private var actionContext: ClipboardPanelActionContext {
        let entry = store.selectedEntry
        let selectedEntries = store.multiSelectionCount > 1
            ? store.selectedEntriesInOrder
            : entry.map { [$0] } ?? []
        return ClipboardPanelActionContext(
            entry: entry,
            selectedEntries: selectedEntries,
            canCopyPlainText: entry.map(store.canCopyPlainText) ?? false,
            canMergePlainText: store.canMergePlainText(selectedEntries),
            hasOpenableURL: entry?.webURL != nil,
            hasFiles: !(entry?.fileURLs.isEmpty ?? true)
        )
    }

    @ViewBuilder
    private var searchControls: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)

            TextField(L("Search Clipboard History"), text: $store.query)
                .textFieldStyle(.plain)
                .font(ClipboardTypography.search)
                .foregroundStyle(ClipboardTypography.primaryText)
                .focused($searchFocused)
                .clipboardSearchWritingToolsDisabled()

            searchFilterMenu

            if !store.query.isEmpty {
                Button {
                    store.query = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L("Clear Search"))
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 36)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(
                    Color.primary.opacity(colorSchemeContrast == .increased ? 0.35 : 0.12),
                    lineWidth: colorSchemeContrast == .increased ? 1.1 : 0.7
                )
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if !searchFocused {
                searchFocused = true
            }
        }
    }

    private var searchFilterMenu: some View {
        Menu {
            if let source = store.selectedEntry?.sourceApplicationName
                ?? store.selectedEntry?.sourceBundleIdentifier {
                Button(String(format: L("Filter Current Source Application"), source)) {
                    store.appendSearchFilter(field: .application, value: source)
                    searchFocused = true
                }
                Divider()
            }

            Section(L("Clipboard Content Type")) {
                Button(L("Text")) {
                    store.appendSearchFilter(field: .type, value: "text")
                }
                Button(L("Rich Text")) {
                    store.appendSearchFilter(field: .type, value: "richtext")
                }
                Button(L("Link")) {
                    store.appendSearchFilter(field: .type, value: "url")
                }
                Button(L("File")) {
                    store.appendSearchFilter(field: .type, value: "file")
                }
                Button(L("Image")) {
                    store.appendSearchFilter(field: .type, value: "image")
                }
            }

            Section(L("Clipboard Item State")) {
                Button(L("Only Reusable Items")) {
                    store.appendSearchFilter(field: .state, value: "pinned")
                }
                Button(L("Only Snippets")) {
                    store.appendSearchFilter(field: .state, value: "snippet")
                }
                if let collection = store.selectedEntry?.snippetCollection,
                   !collection.isEmpty {
                    Button(String(format: L("Filter Current Snippet Collection"), collection)) {
                        store.appendSearchFilter(field: .collection, value: collection)
                    }
                }
            }

            if store.hasStructuredSearchFilters {
                Divider()
                Button(L("Remove Search Filters")) {
                    store.removeSearchFilters()
                    searchFocused = true
                }
            }
        } label: {
            Image(systemName: store.hasStructuredSearchFilters
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(store.hasStructuredSearchFilters
                    ? Color.accentColor : Color.secondary)
                .frame(width: 22, height: 22)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("Clipboard Search Filter Help"))
        .accessibilityLabel(Text(L("Clipboard Search Filters")))
    }
}

private extension View {
    @ViewBuilder
    func clipboardSearchWritingToolsDisabled() -> some View {
        if #available(macOS 15.0, *) {
            writingToolsBehavior(.disabled)
        } else {
            self
        }
    }
}

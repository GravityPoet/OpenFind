import SwiftUI

struct ClipboardHistoryHeader: View {
    @Bindable var store: ClipboardHistoryStore
    @FocusState.Binding var searchFocused: Bool
    @Binding var isActionPanelPresented: Bool
    let onPerformAction: (ClipboardPanelAction) -> Void
    let onPerformContentAction: (ClipboardContentActionDescriptor) -> Void

    var body: some View {
        OpenFindGlassContainer {
            HStack(spacing: 8) {
                searchControls

                Button {
                    isActionPanelPresented.toggle()
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .openFindGlassCapsule()
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
        .openFindInteractiveGlassRoundedRectangle(cornerRadius: 11)
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.white.opacity(0.20), lineWidth: 0.7)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if !searchFocused {
                searchFocused = true
            }
        }
    }
}

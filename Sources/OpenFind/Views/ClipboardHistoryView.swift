import SwiftUI

struct ClipboardHistoryView: View {
    @Bindable var store: ClipboardHistoryStore
    let onPaste: (ClipboardEntry, Bool) -> Void
    let onStartPasteStack: (Bool) -> Void
    let onPreviewVisibilityChange: (Bool) -> Void
    let onActionPanelVisibilityChange: (Bool) -> Void
    let onQuickLook: ([URL]) -> Void
    let onCancelPasteStack: () -> Void
    let onClose: () -> Void
    @FocusState var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ClipboardHistoryHeader(
                store: store,
                searchFocused: $searchFocused,
                isActionPanelPresented: $store.isActionPanelPresented,
                onPerformAction: performPanelAction
            )

            if let error = store.lastErrorMessage {
                ClipboardErrorBanner(message: error) { store.clearError() }
            }
            if let pasteStack = store.pasteStack {
                ClipboardPasteStackStatusView(
                    stack: pasteStack,
                    onCancel: onCancelPasteStack
                )
            }

            ClipboardHistoryContent(
                store: store,
                onUse: performDefaultAction,
                onCopy: { copy($0) },
                onPaste: { paste($0) },
                onPastePlainText: { paste($0, plainTextOnly: true) },
                onPin: { store.togglePinned($0) },
                onDelete: { store.delete($0) }
            )
            if store.preferences.showFooter {
                ClipboardHistoryFooter(store: store)
            }
        }
        .frame(
            minWidth: store.isPreviewVisible ? 680 : 420,
            idealWidth: store.isPreviewVisible ? 760 : 450,
            minHeight: 440,
            idealHeight: 500
        )
        .background(
            .ultraThinMaterial,
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.24), lineWidth: 0.8)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .ignoresSafeArea(edges: .top)
        .background {
            keyMonitor.frame(width: 0, height: 0)
        }
        .onAppear {
            store.selectedIndex = min(store.selectedIndex, max(0, store.filteredEntries.count - 1))
            requestSearchFocus()
        }
        .onChange(of: store.query) {
            store.selectedIndex = 0
            store.clearMultiSelection()
        }
        .onChange(of: store.isSearchPresented) {
            requestSearchFocus()
        }
        .onChange(of: store.isActionPanelPresented) {
            onActionPanelVisibilityChange(store.isActionPanelPresented)
            guard !store.isActionPanelPresented else { return }
            requestSearchFocus()
        }
        .onChange(of: store.presentationGeneration) {
            guard store.isPanelPresented else { return }
            requestSearchFocus()
        }
        .onDisappear {
            store.isActionPanelPresented = false
        }
    }

    private func requestSearchFocus() {
        searchFocused = false
        Task { @MainActor in
            await Task.yield()
            guard store.isPanelPresented, !store.isActionPanelPresented else { return }
            searchFocused = true
        }
    }
}

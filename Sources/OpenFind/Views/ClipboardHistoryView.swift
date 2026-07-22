import SwiftUI

struct ClipboardHistoryView: View {
    @Bindable var store: ClipboardHistoryStore
    let onPaste: (ClipboardEntry, Bool) -> Void
    let onStartPasteStack: (Bool) -> Void
    let onPreviewVisibilityChange: (Bool) -> Void
    let onCancelPasteStack: () -> Void
    let onClose: () -> Void
    @FocusState var searchFocused: Bool
    @State var previewTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            ClipboardHistoryHeader(
                store: store,
                searchFocused: $searchFocused
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
        .background { keyMonitor.frame(width: 0, height: 0) }
        .onAppear {
            store.selectedIndex = min(store.selectedIndex, max(0, store.filteredEntries.count - 1))
            searchFocused = true
            scheduleAutomaticPreview()
        }
        .onChange(of: store.query) {
            store.selectedIndex = 0
            store.clearMultiSelection()
        }
        .onChange(of: store.selectedIndex) { scheduleAutomaticPreview() }
        .onChange(of: store.isSearchPresented) {
            Task { @MainActor in
                await Task.yield()
                searchFocused = true
            }
        }
        .onChange(of: store.presentationGeneration) {
            previewTask?.cancel()
            guard store.isPanelPresented else { return }
            searchFocused = true
            scheduleAutomaticPreview()
        }
        .onDisappear { previewTask?.cancel() }
    }
}

import SwiftUI

struct ClipboardHistoryView: View {
    @Bindable var store: ClipboardHistoryStore
    let onPaste: (ClipboardEntry, Bool) -> Void
    let onStartPasteStack: (Bool) -> Void
    let onPreviewVisibilityChange: (Bool) -> Void
    let onActionPanelVisibilityChange: (Bool) -> Void
    let onQuickLook: (ClipboardEntry) -> Void
    let onCancelPasteStack: () -> Void
    let onClose: () -> Void
    @FocusState var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @State private var searchFocusTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            ClipboardHistoryHeader(
                store: store,
                searchFocused: $searchFocused,
                isActionPanelPresented: $store.isActionPanelPresented,
                onPerformAction: performPanelAction,
                onPerformContentAction: performContentAction
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
            panelSurface,
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    Color.primary.opacity(colorSchemeContrast == .increased ? 0.34 : 0.12),
                    lineWidth: colorSchemeContrast == .increased ? 1.2 : 0.8
                )
        }
        .overlay(alignment: .bottom) {
            if store.canUndoDeletion {
                ClipboardUndoBanner(itemCount: store.undoDeletionCount) {
                    store.undoLastDeletion()
                }
                .padding(.bottom, store.preferences.showFooter ? 45 : 10)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: store.canUndoDeletion)
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
            searchFocusTask?.cancel()
            searchFocusTask = nil
            store.isActionPanelPresented = false
        }
        .openFindInterfaceSizing()
    }

    private func requestSearchFocus() {
        searchFocusTask?.cancel()
        searchFocused = false
        guard store.isPanelPresented, !store.isActionPanelPresented else { return }
        let generation = store.presentationGeneration
        searchFocusTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled,
                  store.isPanelPresented,
                  store.presentationGeneration == generation,
                  !store.isActionPanelPresented else { return }
            searchFocused = true
            searchFocusTask = nil
        }
    }

    private var panelSurface: AnyShapeStyle {
        if reduceTransparency {
            return AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
        }
        return AnyShapeStyle(Material.ultraThinMaterial)
    }
}

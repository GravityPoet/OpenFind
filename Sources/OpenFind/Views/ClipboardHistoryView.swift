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
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @State private var searchFocusTask: Task<Void, Never>?
    @State var noteEditorRequest: ClipboardNoteEditRequest?

    var body: some View {
        VStack(spacing: 0) {
            ClipboardHistoryHeader(
                store: store,
                searchFocused: $searchFocused,
                isActionPanelPresented: $store.isActionPanelPresented,
                onPerformAction: performPanelAction,
                onPerformContentAction: performContentAction,
                onUseFrequentEntry: { entry in
                    store.clearMultiSelection()
                    performDefaultAction(entry)
                }
            )

            let captureStatus = ClipboardCaptureStatus.resolve(
                capturePaused: store.preferences.capturePaused,
                ignoreOnlyNextCapture: store.preferences.ignoreOnlyNextCapture
            )
            if captureStatus != .active {
                ClipboardCaptureStatusBanner(status: captureStatus) {
                    store.setCapturePaused(false)
                }
            }

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
                onEditNote: beginEditingNote,
                onToggleFrequentlyUsed: { store.toggleFrequentlyUsed($0) },
                onPin: { store.togglePinned($0) },
                onDelete: { store.delete($0) },
                onRevealPreview: revealPreview
            )
            if store.preferences.showFooter {
                ClipboardHistoryFooter(store: store)
            }
        }
        .frame(
            minWidth: store.isPreviewVisible
                ? ClipboardHistoryPanelMetrics.expandedMinimumSize.width
                : ClipboardHistoryPanelMetrics.compactMinimumSize.width,
            idealWidth: store.isPreviewVisible
                ? ClipboardHistoryPanelMetrics.expandedDefaultSize.width
                : ClipboardHistoryPanelMetrics.compactDefaultSize.width,
            minHeight: ClipboardHistoryPanelMetrics.compactMinimumSize.height,
            idealHeight: ClipboardHistoryPanelMetrics.compactDefaultSize.height
        )
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(panelSurface)
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(panelAmbientGradient)
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    Color.primary.opacity(colorSchemeContrast == .increased ? 0.34 : 0.12),
                    lineWidth: colorSchemeContrast == .increased ? 1.2 : 0.8
                )
        }
        .overlay(alignment: .bottom) {
            if store.isDeletionUndoBannerPresented {
                ClipboardUndoBanner(itemCount: store.undoDeletionCount) {
                    store.undoLastDeletion()
                }
                .padding(.bottom, store.preferences.showFooter ? 42 : 10)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(
            reduceMotion ? nil : .snappy(duration: 0.2),
            value: store.isDeletionUndoBannerPresented
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .ignoresSafeArea(edges: .top)
        .background {
            keyMonitor.frame(width: 0, height: 0)
        }
        .sheet(item: $noteEditorRequest, onDismiss: requestSearchFocus) { request in
            ClipboardNoteEditor(
                entry: request.entry,
                onSave: { note in
                    store.setCustomTitle(note, for: request.entry)
                    noteEditorRequest = nil
                },
                onCancel: { noteEditorRequest = nil }
            )
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
        .onChange(of: store.isPreviewVisible) {
            onPreviewVisibilityChange(store.isPreviewVisible)
        }
        .onChange(of: store.presentationGeneration) {
            guard store.isPanelPresented else { return }
            requestSearchFocus()
        }
        .onDisappear {
            searchFocusTask?.cancel()
            searchFocusTask = nil
            noteEditorRequest = nil
            store.isActionPanelPresented = false
        }
        .openFindInterfaceSizing()
    }

    private func requestSearchFocus() {
        searchFocusTask?.cancel()
        searchFocused = false
        guard store.isPanelPresented,
              !store.isActionPanelPresented,
              noteEditorRequest == nil else { return }
        let generation = store.presentationGeneration
        searchFocusTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled,
                  store.isPanelPresented,
                  store.presentationGeneration == generation,
                  !store.isActionPanelPresented,
                  noteEditorRequest == nil else { return }
            searchFocused = true
            searchFocusTask = nil
        }
    }

    private func revealPreview() {
        guard store.isPanelPresented, !store.isPreviewVisible else { return }
        store.isPreviewVisible = true
    }

    private var panelSurface: AnyShapeStyle {
        if reduceTransparency {
            return AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
        }
        return AnyShapeStyle(Material.ultraThinMaterial)
    }

    private var panelAmbientGradient: LinearGradient {
        let blueOpacity: Double
        let neutralOpacity: Double
        if colorSchemeContrast == .increased {
            blueOpacity = 0
            neutralOpacity = 0
        } else if colorScheme == .dark {
            blueOpacity = 0.028
            neutralOpacity = 0.010
        } else {
            blueOpacity = 0.016
            neutralOpacity = 0.005
        }

        return LinearGradient(
            stops: [
                .init(color: Color.accentColor.opacity(blueOpacity), location: 0),
                .init(color: Color.accentColor.opacity(blueOpacity * 0.28), location: 0.24),
                .init(color: Color.clear, location: 0.54),
                .init(color: Color.primary.opacity(neutralOpacity), location: 1)
            ],
            startPoint: .topTrailing,
            endPoint: .bottomLeading
        )
    }
}

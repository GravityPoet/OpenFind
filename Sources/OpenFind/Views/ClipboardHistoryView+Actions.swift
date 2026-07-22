import SwiftUI

extension ClipboardHistoryView {
    func performDefaultAction() {
        guard let selected = store.selectedEntry else { return }
        performDefaultAction(selected)
    }

    func performDefaultAction(_ entry: ClipboardEntry) {
        if store.multiSelectionCount > 1 {
            onStartPasteStack(false)
        } else {
            paste(entry)
        }
    }

    func performQuickAction(index: Int, action: ClipboardQuickAction) {
        let entries = store.filteredEntries.filter { !$0.isPinned }
        guard entries.indices.contains(index) else { return }
        let entry = entries[index]
        store.clearMultiSelection()
        store.select(entry)
        perform(action, on: entry)
    }

    func performPinnedAction(key: String, action: ClipboardQuickAction) {
        guard let entry = store.filteredEntries.first(where: {
            $0.isPinned && ClipboardPinKey.normalize($0.pinKey) == key
        }) else { return }
        store.select(entry)
        perform(action, on: entry)
    }

    func perform(_ action: ClipboardQuickAction, on entry: ClipboardEntry) {
        switch action {
        case .copy: copy(entry)
        case .paste: paste(entry)
        case .pastePlainText: paste(entry, plainTextOnly: true)
        }
    }

    func pasteSelected(plainTextOnly: Bool = false) {
        if store.multiSelectionCount > 1 {
            onStartPasteStack(plainTextOnly)
            return
        }
        guard let selected = store.selectedEntry else { return }
        paste(selected, plainTextOnly: plainTextOnly)
    }

    func paste(_ entry: ClipboardEntry, plainTextOnly: Bool = false) {
        guard !plainTextOnly || store.canCopyPlainText(entry) else { return }
        onPaste(entry, plainTextOnly)
    }

    func copySelectedPlainText() {
        guard let selected = store.selectedEntry else { return }
        copy(selected, plainTextOnly: true)
    }

    func copy(_ entry: ClipboardEntry, plainTextOnly: Bool = false) {
        guard !plainTextOnly || store.canCopyPlainText(entry) else { return }
        do {
            try store.copy(entry, plainTextOnly: plainTextOnly)
            onClose()
        } catch {
            store.reportError(error)
        }
    }

    func toggleSelectedPin() {
        guard let selected = store.selectedEntry else { return }
        store.togglePinned(selected)
    }

    func deleteSelected() {
        store.deleteSelection()
    }

    func togglePreview() {
        previewTask?.cancel()
        let visible = !store.isPreviewVisible
        store.isPreviewVisible = visible
        onPreviewVisibilityChange(visible)
    }

    func scheduleAutomaticPreview() {
        previewTask?.cancel()
        guard store.preferences.openPreviewAutomatically,
              store.isPanelPresented,
              !store.isPreviewVisible else { return }
        let selectedID = store.selectedEntry?.id
        let generation = store.presentationGeneration
        let delay = store.preferences.previewDelayMilliseconds
        previewTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled,
                  store.isPanelPresented,
                  store.presentationGeneration == generation,
                  store.selectedEntry?.id == selectedID else { return }
            store.isPreviewVisible = true
            onPreviewVisibilityChange(true)
        }
    }
}

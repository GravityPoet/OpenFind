import SwiftUI

extension ClipboardHistoryView {
    var keyMonitor: ClipboardHistoryKeyMonitor {
        ClipboardHistoryKeyMonitor(
            isPanelPresented: store.isPanelPresented,
            isSearchPresented: store.isSearchPresented,
            isActionPanelPresented: store.isActionPanelPresented,
            pinShortcut: store.preferences.pinShortcut,
            deleteShortcut: store.preferences.deleteShortcut,
            previewShortcut: store.preferences.previewShortcut,
            onMove: { store.moveSelection(by: $0) },
            onSelectBoundary: { first in
                guard !store.filteredEntries.isEmpty else { return }
                store.clearMultiSelection()
                store.selectedIndex = first ? 0 : store.filteredEntries.count - 1
            },
            onExtend: { store.extendSelection(by: $0) },
            onExtendBoundary: { store.extendSelectionToBoundary(first: $0) },
            onDefaultAction: performDefaultAction,
            onPaste: { pasteSelected(plainTextOnly: $0) },
            onCopyPlainText: { copySelectedPlainText() },
            onTogglePin: { toggleSelectedPin() },
            onSaveForReuse: { saveSelectedForReuse() },
            onToggleActions: { store.isActionPanelPresented.toggle() },
            onTogglePreview: { togglePreview() },
            onDelete: { deleteSelected() },
            onClear: { all in all ? store.clearAll() : store.clearUnpinned() },
            onUndo: { store.undoLastDeletion() },
            onEscape: handleEscape,
            onBeginSearch: { beginSearch(with: $0) },
            onQuickAction: performQuickAction,
            onPinnedAction: performPinnedAction
        )
    }

    func handleEscape() {
        if store.isActionPanelPresented {
            store.isActionPanelPresented = false
        } else {
            onClose()
        }
    }

    func beginSearch(with initialText: String = "") {
        store.isSearchPresented = true
        searchFocused = true
        if !initialText.isEmpty { store.query.append(initialText) }
    }
}

import AppKit
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

    func saveSelectedForReuse() {
        guard let selected = store.selectedEntry else { return }
        store.saveForReuse(selected)
    }

    func performPanelAction(_ action: ClipboardPanelAction) {
        store.isActionPanelPresented = false
        switch action {
        case .paste:
            pasteSelected()
        case .pastePlainText:
            pasteSelected(plainTextOnly: true)
        case .copy:
            guard let selected = store.selectedEntry else { return }
            copy(selected)
        case .copyPlainText:
            copySelectedPlainText()
        case .pasteSelection:
            onStartPasteStack(false)
        case .pasteSelectionPlainText:
            onStartPasteStack(true)
        case .mergeSelectionPlainText:
            copyMergedSelection()
        case .openURL:
            guard let url = store.selectedEntry?.webURL else { return }
            onClose()
            NSWorkspace.shared.open(url)
        case .openFiles:
            let urls = store.selectedEntry?.fileURLs ?? []
            guard !urls.isEmpty else { return }
            onClose()
            urls.forEach { NSWorkspace.shared.open($0) }
        case .revealFiles:
            let urls = store.selectedEntry?.fileURLs ?? []
            guard !urls.isEmpty else { return }
            onClose()
            FileActions.revealInFinder(urls)
        case .quickLookFiles:
            let urls = store.selectedEntry?.fileURLs ?? []
            guard !urls.isEmpty else { return }
            onClose()
            onQuickLook(urls)
        case .saveForReuse:
            saveSelectedForReuse()
        case .removeFromSaved:
            guard let selected = store.selectedEntry, selected.isPinned else { return }
            store.togglePinned(selected)
        case .delete:
            deleteSelected()
        case .clearRecentFiveMinutes:
            store.clearRecent(minutes: 5)
        case .clearRecentFifteenMinutes:
            store.clearRecent(minutes: 15)
        case .clearUnpinned:
            store.clearUnpinned()
        }
    }

    func copyMergedSelection() {
        do {
            try store.copyMergedPlainText(store.selectedEntriesInOrder)
            onClose()
        } catch {
            store.reportError(error)
        }
    }

    func deleteSelected() {
        store.deleteSelection()
    }

    func togglePreview() {
        let visible = !store.isPreviewVisible
        store.isPreviewVisible = visible
        onPreviewVisibilityChange(visible)
    }
}

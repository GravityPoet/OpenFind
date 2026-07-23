import AppKit
import Foundation

extension ClipboardHistoryStore {
    @discardableResult
    func copy(_ entry: ClipboardEntry, plainTextOnly: Bool = false) throws -> Int {
        guard entries.contains(where: { $0.id == entry.id }) else {
            throw ClipboardHistoryError.entryNotFound
        }
        if entry.isPinned,
           entry.snippetExpansionEnabled != nil,
           let template = plainText(for: entry) {
            let rendered = ClipboardSnippetRenderer.render(
                template,
                clipboardText: { [pasteboard] in pasteboard.string(forType: .string) }
            )
            try writePlainText(rendered.text)
            return rendered.cursorOffsetFromEnd
        }
        if plainTextOnly {
            guard let text = plainText(for: entry) else {
                throw ClipboardHistoryError.unsupportedContent
            }
            try writePlainText(text)
            return 0
        }
        let items = entry.retainedPasteboardItems.enumerated().map { index, representations in
            let item = NSPasteboardItem()
            for (type, data) in representations {
                item.setData(data, forType: NSPasteboard.PasteboardType(rawValue: type))
            }
            if index == 0 {
                item.setString("", forType: .init(Self.internalPasteboardType))
            }
            return item
        }
        pasteboard.clearContents()
        guard !items.isEmpty, pasteboard.writeObjects(items) else {
            throw ClipboardHistoryError.pasteboardWriteFailed
        }
        return 0
    }

    func canCopyPlainText(_ entry: ClipboardEntry) -> Bool {
        plainText(for: entry) != nil
    }

    func canMergePlainText(_ selectedEntries: [ClipboardEntry]) -> Bool {
        selectedEntries.count > 1 && selectedEntries.allSatisfy { plainText(for: $0) != nil }
    }

    func availableContentActions(
        for entry: ClipboardEntry
    ) -> [ClipboardContentActionDescriptor] {
        guard let text = plainText(for: entry) else { return [] }
        return contentActionRegistry.actions(for: text)
    }

    func performContentAction(
        _ action: ClipboardContentActionDescriptor,
        on entry: ClipboardEntry
    ) throws {
        guard entries.contains(where: { $0.id == entry.id }),
              let text = plainText(for: entry) else {
            throw ClipboardHistoryError.entryNotFound
        }
        let transformed = try contentActionRegistry.transform(
            actionID: action.id,
            text: text
        )
        try writePlainText(transformed)
    }

    func copyMergedPlainText(_ selectedEntries: [ClipboardEntry]) throws {
        guard canMergePlainText(selectedEntries) else {
            throw ClipboardHistoryError.unsupportedContent
        }
        let text = selectedEntries.compactMap(plainText).joined(separator: "\n")
        try writePlainText(text)
    }

    func prepareForTermination() {
        if clearHistoryOnQuit { clearAll(recordsUndo: false) }
        if clearSystemClipboardOnQuit { pasteboard.clearContents() }
    }

    func delete(_ entry: ClipboardEntry) {
        guard let entryIndex = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        let selectedID = selectedEntry?.id
        let deletedSelectedEntry = selectedID == entry.id
        recordDeletionUndo(
            [ClipboardDeletionUndo.RemovedEntry(index: entryIndex, entry: entries[entryIndex])],
            selectedEntryID: selectedID
        )
        entries.remove(at: entryIndex)
        removeInvalidSelections()
        if !deletedSelectedEntry,
           let selectedID,
           let newIndex = visibleIndex(for: selectedID) {
            selectedIndex = newIndex
        } else {
            selectedIndex = min(selectedIndex, max(0, filteredEntries.count - 1))
        }
        persist()
    }

    func deleteSelection() {
        let ids = Set(selectedEntryIDs)
        guard !ids.isEmpty else {
            if let selectedEntry { delete(selectedEntry) }
            return
        }
        let removed = entries.enumerated().compactMap { index, entry in
            ids.contains(entry.id)
                ? ClipboardDeletionUndo.RemovedEntry(index: index, entry: entry)
                : nil
        }
        guard !removed.isEmpty else { return }
        recordDeletionUndo(removed, selectedEntryID: selectedEntry?.id)
        entries.removeAll { ids.contains($0.id) }
        clearMultiSelection()
        selectedIndex = min(selectedIndex, max(0, filteredEntries.count - 1))
        persist()
    }

    func togglePinned(_ entry: ClipboardEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index].isPinned.toggle()
        if entries[index].isPinned {
            entries[index].pinKey = ClipboardPinKey.available(
                in: entries,
                excluding: entry.id
            ).first
        } else {
            entries[index].pinKey = nil
            entries[index].snippetCollection = nil
            entries[index].snippetKeyword = nil
            entries[index].snippetExpansionEnabled = nil
        }
        restoreSelection(id: entry.id)
        persist()
    }

    @discardableResult
    func saveForReuse(_ entry: ClipboardEntry) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return false }
        guard !entries[index].isPinned else { return true }
        entries[index].isPinned = true
        entries[index].pinKey = ClipboardPinKey.available(
            in: entries,
            excluding: entry.id
        ).first
        restoreSelection(id: entry.id)
        persist()
        return true
    }

    func clearRecent(minutes: Int, referenceDate: Date = Date()) {
        guard minutes > 0 else { return }
        let cutoff = referenceDate.addingTimeInterval(-TimeInterval(minutes * 60))
        let selectedID = selectedEntry?.id
        let removed = entries.enumerated().compactMap { index, entry in
            !entry.isPinned && entry.createdAt >= cutoff
                ? ClipboardDeletionUndo.RemovedEntry(index: index, entry: entry)
                : nil
        }
        guard !removed.isEmpty else { return }
        recordDeletionUndo(removed, selectedEntryID: selectedID)
        let ids = Set(removed.map(\.entry.id))
        entries.removeAll { ids.contains($0.id) }
        removeInvalidSelections()
        restoreSelection(id: selectedID)
        persist()
    }

    func clearUnpinned() {
        let removed = entries.enumerated().compactMap { index, entry in
            !entry.isPinned
                ? ClipboardDeletionUndo.RemovedEntry(index: index, entry: entry)
                : nil
        }
        guard !removed.isEmpty else { return }
        recordDeletionUndo(removed, selectedEntryID: selectedEntry?.id)
        let ids = Set(removed.map(\.entry.id))
        entries.removeAll { ids.contains($0.id) }
        selectedIndex = 0
        removeInvalidSelections()
        persist()
    }

    func clearAll(recordsUndo: Bool = true) {
        guard !entries.isEmpty else { return }
        if recordsUndo {
            let removed = entries.enumerated().map {
                ClipboardDeletionUndo.RemovedEntry(index: $0.offset, entry: $0.element)
            }
            recordDeletionUndo(removed, selectedEntryID: selectedEntry?.id)
        } else {
            deletionUndo = nil
        }
        entries.removeAll()
        selectedIndex = 0
        clearMultiSelection()
        cancelPasteStack()
        persist()
    }

    @discardableResult
    func undoLastDeletion() -> Bool {
        guard let undo = deletionUndo else { return false }
        deletionUndo = nil

        let removedIDs = Set(undo.removedEntries.map(\.entry.id))
        let newEntries = entries.filter {
            !undo.survivingEntryIDs.contains($0.id) && !removedIDs.contains($0.id)
        }
        var restored = entries.filter { undo.survivingEntryIDs.contains($0.id) }
        let existingIDs = Set(entries.map(\.id))
        for removed in undo.removedEntries.sorted(by: { $0.index < $1.index })
            where !existingIDs.contains(removed.entry.id) {
            restored.insert(removed.entry, at: min(removed.index, restored.count))
        }
        entries = newEntries + restored
        clearMultiSelection()
        restoreSelection(
            id: undo.selectedEntryID ?? undo.removedEntries.first?.entry.id
        )
        persist()
        enqueueMissingImageTextRecognition()
        return true
    }

    func dismissDeletionUndo() {
        deletionUndo = nil
    }

    func clearError() {
        lastErrorMessage = nil
    }

    func reportError(_ error: Error) {
        if let error = error as? LocalizedError,
           let description = error.errorDescription,
           !description.isEmpty {
            lastErrorMessage = description
        } else {
            lastErrorMessage = L("Clipboard Operation Failed")
        }
    }

    func plainText(for entry: ClipboardEntry) -> String? {
        if let data = entry.representations[NSPasteboard.PasteboardType.string.rawValue]
            ?? entry.representations["public.utf8-plain-text"],
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        if let data = entry.representations["public.utf16-external-plain-text"],
           let text = String(data: data, encoding: .utf16) {
            return text
        }
        if entry.kind == .url { return entry.previewText }
        if preferences.imageTextRecognitionEnabled,
           entry.kind == .image,
           let text = entry.recognizedText,
           !text.isEmpty {
            return text
        }
        return nil
    }

    func writePlainText(_ text: String) throws {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setString("", forType: .init(Self.internalPasteboardType))
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            throw ClipboardHistoryError.pasteboardWriteFailed
        }
    }

    private func recordDeletionUndo(
        _ removedEntries: [ClipboardDeletionUndo.RemovedEntry],
        selectedEntryID: UUID?
    ) {
        guard !removedEntries.isEmpty else { return }
        let removedIDs = Set(removedEntries.map(\.entry.id))
        deletionUndo = ClipboardDeletionUndo(
            removedEntries: removedEntries,
            survivingEntryIDs: Set(entries.lazy.filter {
                !removedIDs.contains($0.id)
            }.map(\.id)),
            selectedEntryID: selectedEntryID
        )
    }
}

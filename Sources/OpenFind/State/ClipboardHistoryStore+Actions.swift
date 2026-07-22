import AppKit
import Foundation

extension ClipboardHistoryStore {
    func copy(_ entry: ClipboardEntry, plainTextOnly: Bool = false) throws {
        guard entries.contains(where: { $0.id == entry.id }) else {
            throw ClipboardHistoryError.entryNotFound
        }
        if plainTextOnly {
            guard let text = plainText(for: entry) else {
                throw ClipboardHistoryError.unsupportedContent
            }
            try writePlainText(text)
            return
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
    }

    func canCopyPlainText(_ entry: ClipboardEntry) -> Bool {
        plainText(for: entry) != nil
    }

    func canMergePlainText(_ selectedEntries: [ClipboardEntry]) -> Bool {
        selectedEntries.count > 1 && selectedEntries.allSatisfy { plainText(for: $0) != nil }
    }

    func copyMergedPlainText(_ selectedEntries: [ClipboardEntry]) throws {
        guard canMergePlainText(selectedEntries) else {
            throw ClipboardHistoryError.unsupportedContent
        }
        let text = selectedEntries.compactMap(plainText).joined(separator: "\n")
        try writePlainText(text)
    }

    func prepareForTermination() {
        if clearHistoryOnQuit { clearAll() }
        if clearSystemClipboardOnQuit { pasteboard.clearContents() }
    }

    func delete(_ entry: ClipboardEntry) {
        let selectedID = selectedEntry?.id
        let deletedSelectedEntry = selectedID == entry.id
        entries.removeAll { $0.id == entry.id }
        removeInvalidSelections()
        if !deletedSelectedEntry,
           let selectedID,
           let newIndex = filteredEntries.firstIndex(where: { $0.id == selectedID }) {
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
        entries.removeAll { !$0.isPinned && $0.createdAt >= cutoff }
        removeInvalidSelections()
        restoreSelection(id: selectedID)
        persist()
    }

    func clearUnpinned() {
        entries.removeAll { !$0.isPinned }
        selectedIndex = 0
        removeInvalidSelections()
        persist()
    }

    func clearAll() {
        entries.removeAll()
        selectedIndex = 0
        clearMultiSelection()
        cancelPasteStack()
        persist()
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
        return nil
    }

    private func writePlainText(_ text: String) throws {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setString("", forType: .init(Self.internalPasteboardType))
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            throw ClipboardHistoryError.pasteboardWriteFailed
        }
    }
}

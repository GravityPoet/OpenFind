import AppKit
import CryptoKit
import Foundation

extension ClipboardHistoryStore {
    @discardableResult
    func copy(_ entry: ClipboardEntry, plainTextOnly: Bool = false) throws -> Int {
        guard entries.contains(where: { $0.id == entry.id }) else {
            throw ClipboardHistoryError.entryNotFound
        }
        let entry = try materializedEntry(for: entry)
        if entry.isPinned,
           entry.snippetExpansionEnabled != nil,
           let template = plainText(for: entry) {
            let rendered = ClipboardSnippetRenderer.render(
                template,
                clipboardText: { [pasteboard] in pasteboard.string(forType: .string) }
            )
            try writePlainText(rendered.text)
            recordUse(of: entry.id)
            return rendered.cursorOffsetFromEnd
        }
        if plainTextOnly {
            guard let text = plainText(for: entry) else {
                throw ClipboardHistoryError.unsupportedContent
            }
            try writePlainText(text)
            recordUse(of: entry.id)
            return 0
        }
        let items = entry.retainedPasteboardItems.enumerated().map { index, representations in
            let item = NSPasteboardItem()
            for (type, data) in representations {
                item.setData(data, forType: NSPasteboard.PasteboardType(rawValue: type))
            }
            if index == 0 {
                item.setString("", forType: .init(Self.internalPasteboardType))
                if let sourceBundleIdentifier = normalizedMetadata(
                    entry.sourceBundleIdentifier,
                    limit: 512
                ) {
                    item.setString(
                        sourceBundleIdentifier,
                        forType: .init(Self.sourcePasteboardType)
                    )
                }
            }
            return item
        }
        pasteboard.clearContents()
        guard !items.isEmpty, pasteboard.writeObjects(items) else {
            throw ClipboardHistoryError.pasteboardWriteFailed
        }
        recordUse(of: entry.id)
        return 0
    }

    private func recordUse(of id: UUID, at date: Date = Date()) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        var updated = entries[index]
        let decayedScore = updated.lastUsedAt == nil
            ? max(0, updated.usageScore ?? Double(updated.numberOfUses))
            : updated.decayedUsageScore(at: date)
        updated.lastUsedAt = date
        updated.useCount = updated.numberOfUses == Int.max
            ? Int.max
            : updated.numberOfUses + 1
        updated.usageScore = decayedScore + 1
        entries[index] = updated
        persist()
    }

    func canCopyPlainText(_ entry: ClipboardEntry) -> Bool {
        entry.resolvedPayloadDescriptor?.hasPlainText == true
            || entry.kind == .url
            || (preferences.imageTextRecognitionEnabled
                && entry.kind == .image
                && entry.recognizedText?.isEmpty == false)
    }

    func canMergePlainText(_ selectedEntries: [ClipboardEntry]) -> Bool {
        selectedEntries.count > 1 && selectedEntries.allSatisfy(canCopyPlainText)
    }

    func availableContentActions(
        for entry: ClipboardEntry
    ) -> [ClipboardContentActionDescriptor] {
        guard let materialized = try? materializedEntry(for: entry),
              let text = plainText(for: materialized) else { return [] }
        return contentActionRegistry.actions(for: text)
    }

    func performContentAction(
        _ action: ClipboardContentActionDescriptor,
        on entry: ClipboardEntry
    ) throws {
        guard entries.contains(where: { $0.id == entry.id }),
              let text = try plainTextMaterializing(for: entry) else {
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
        let text = try selectedEntries.compactMap {
            try plainTextMaterializing(for: $0)
        }.joined(separator: "\n")
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
        guard recordDeletionUndo(
            [ClipboardDeletionUndo.RemovedEntry(index: entryIndex, entry: entries[entryIndex])],
            selectedEntryID: selectedID
        ) else { return }
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
        guard recordDeletionUndo(removed, selectedEntryID: selectedEntry?.id) else { return }
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

    func toggleFrequentlyUsed(_ entry: ClipboardEntry, at date: Date = Date()) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        let current = entries[index]
        let shouldRemove = current.frequentOverride == true || isFrequentlyUsed(current)
        entries[index].frequentOverride = shouldRemove ? false : true
        entries[index].frequentOverrideAt = shouldRemove ? nil : date
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
        guard recordDeletionUndo(removed, selectedEntryID: selectedID) else { return }
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
        guard recordDeletionUndo(removed, selectedEntryID: selectedEntry?.id) else { return }
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
            guard recordDeletionUndo(removed, selectedEntryID: selectedEntry?.id) else { return }
        } else {
            clearDeletionUndo()
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
        clearDeletionUndo()

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
        // The undo payload was materialized before deletion. Its database row
        // may already have been removed, so it must be treated as resident
        // when restored instead of being looked up as a cold row.
        nonresidentPayloadEntryIDs.subtract(removedIDs)
        removedIDs.forEach(removeMaterializedPayloadFromCache)
        hasUnpersistedPayloadChanges = true
        clearMultiSelection()
        restoreSelection(
            id: undo.selectedEntryID ?? undo.removedEntries.first?.entry.id
        )
        persist()
        enqueueMissingImageTextRecognition()
        return true
    }

    func dismissDeletionUndo() {
        clearDeletionUndo()
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

    /// Hot-path membership check that avoids decoding cold entries wholesale:
    /// the event-tap callback for Quick Merge runs while the user's Command-C
    /// is suspended. Resident entries still receive an exact representation
    /// comparison; cold entries use the encrypted index's plain-text digest.
    func containsPlainText(_ text: String, inFirst limit: Int) -> Bool {
        let fingerprint = Data(SHA256.hash(data: Data(text.utf8)))
        return entries.prefix(limit).contains { entry in
            if entry.kind == .url { return entry.previewText == text }
            guard entry.previewText == String(text.prefix(4_096)),
                  let descriptor = entry.resolvedPayloadDescriptor,
                  descriptor.hasPlainText else { return false }
            if let storedFingerprint = descriptor.plainTextFingerprint {
                return storedFingerprint == fingerprint
            }
            guard entry.hasResidentPayload,
                  let materialized = try? materializedEntry(for: entry) else { return false }
            return plainText(for: materialized) == text
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

    @discardableResult
    private func recordDeletionUndo(
        _ removedEntries: [ClipboardDeletionUndo.RemovedEntry],
        selectedEntryID: UUID?
    ) -> Bool {
        guard !removedEntries.isEmpty else { return false }
        let materialized: [ClipboardDeletionUndo.RemovedEntry]
        do {
            materialized = try removedEntries.map { removed in
                ClipboardDeletionUndo.RemovedEntry(
                    index: removed.index,
                    entry: try materializedEntry(for: removed.entry)
                )
            }
        } catch {
            reportError(error)
            return false
        }
        let removedIDs = Set(materialized.map(\.entry.id))
        deletionUndo = ClipboardDeletionUndo(
            removedEntries: materialized,
            survivingEntryIDs: Set(entries.lazy.filter {
                !removedIDs.contains($0.id)
            }.map(\.id)),
            selectedEntryID: selectedEntryID
        )
        presentDeletionUndoBanner()
        return true
    }

    private func presentDeletionUndoBanner() {
        deletionUndoBannerDismissTask?.cancel()
        deletionUndoBannerGeneration &+= 1
        let generation = deletionUndoBannerGeneration
        let duration = deletionUndoBannerDuration
        isDeletionUndoBannerPresented = true
        deletionUndoBannerDismissTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: duration)
            } catch {
                return
            }
            guard let self,
                  self.deletionUndoBannerGeneration == generation else { return }
            self.isDeletionUndoBannerPresented = false
            self.deletionUndoBannerDismissTask = nil
        }
    }

    private func clearDeletionUndo() {
        deletionUndoBannerDismissTask?.cancel()
        deletionUndoBannerDismissTask = nil
        deletionUndoBannerGeneration &+= 1
        isDeletionUndoBannerPresented = false
        deletionUndo = nil
    }

    func discardDeletionUndoForBackground() {
        clearDeletionUndo()
    }
}

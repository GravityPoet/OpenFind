import Foundation

extension ClipboardHistoryStore {
    var multiSelectionCount: Int { selectedEntryIDs.count }

    var selectedEntriesInOrder: [ClipboardEntry] {
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        return selectedEntryIDs.compactMap { byID[$0] }
    }

    func selectionOrder(for entry: ClipboardEntry) -> Int? {
        guard let index = selectedEntryIDs.firstIndex(of: entry.id) else { return nil }
        return index + 1
    }

    func clearMultiSelection() {
        selectedEntryIDs = []
        selectionAnchorID = nil
    }

    func toggleMultiSelection(_ entry: ClipboardEntry) {
        guard let visibleIndex = filteredEntries.firstIndex(where: { $0.id == entry.id }) else {
            return
        }
        selectedIndex = visibleIndex
        if let index = selectedEntryIDs.firstIndex(of: entry.id) {
            selectedEntryIDs.remove(at: index)
            if selectedEntryIDs.isEmpty { selectionAnchorID = nil }
        } else {
            selectedEntryIDs.append(entry.id)
            selectionAnchorID = entry.id
        }
    }

    func selectRange(to entry: ClipboardEntry) {
        let visible = filteredEntries
        guard let target = visible.firstIndex(where: { $0.id == entry.id }) else { return }
        let anchorID = selectionAnchorID ?? selectedEntry?.id ?? entry.id
        guard let anchor = visible.firstIndex(where: { $0.id == anchorID }) else {
            toggleMultiSelection(entry)
            return
        }
        selectedIndex = target
        selectionAnchorID = anchorID
        if anchor <= target {
            selectedEntryIDs = Array(visible[anchor...target].map(\.id))
        } else {
            selectedEntryIDs = Array(visible[target...anchor].reversed().map(\.id))
        }
    }

    func extendSelection(by offset: Int) {
        let visible = filteredEntries
        guard !visible.isEmpty else { return }
        let originalIndex = min(max(0, selectedIndex), visible.count - 1)
        let targetIndex = min(visible.count - 1, max(0, originalIndex + offset))
        if selectedEntryIDs.isEmpty {
            selectedEntryIDs = [visible[originalIndex].id]
            selectionAnchorID = visible[originalIndex].id
        }
        selectedIndex = targetIndex
        let targetID = visible[targetIndex].id
        if let existing = selectedEntryIDs.firstIndex(of: targetID),
           existing == selectedEntryIDs.count - 2 {
            selectedEntryIDs.removeLast()
        } else if !selectedEntryIDs.contains(targetID) {
            selectedEntryIDs.append(targetID)
        }
    }

    func extendSelectionToBoundary(first: Bool) {
        let visible = filteredEntries
        guard !visible.isEmpty else { return }
        let target = first ? visible.first! : visible.last!
        selectRange(to: target)
    }

    func removeInvalidSelections() {
        let valid = Set(entries.map(\.id))
        selectedEntryIDs.removeAll { !valid.contains($0) }
        if let selectionAnchorID, !valid.contains(selectionAnchorID) {
            self.selectionAnchorID = nil
        }
    }
}

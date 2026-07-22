import Foundation

extension ClipboardHistoryStore {
    var pasteStackCurrentEntry: ClipboardEntry? {
        guard let id = pasteStack?.currentEntryID else { return nil }
        return entries.first(where: { $0.id == id })
    }

    @discardableResult
    func startPasteStack(plainTextOnly: Bool = false) throws -> ClipboardEntry? {
        let selected = selectedEntriesInOrder
        guard selected.count > 1, let first = selected.first else { return nil }
        let stack = ClipboardPasteStack(
            entryIDs: selected.map(\.id),
            plainTextOnly: plainTextOnly
        )
        pasteStack = stack
        do {
            try copy(first, plainTextOnly: plainTextOnly)
        } catch {
            pasteStack = nil
            throw error
        }
        clearMultiSelection()
        return first
    }

    @discardableResult
    func advancePasteStack() throws -> Bool {
        guard var stack = pasteStack else { return false }
        var nextIndex = stack.currentIndex + 1
        while stack.entryIDs.indices.contains(nextIndex) {
            let nextID = stack.entryIDs[nextIndex]
            if let entry = entries.first(where: { $0.id == nextID }) {
                stack.currentIndex = nextIndex
                pasteStack = stack
                do {
                    try copy(entry, plainTextOnly: stack.plainTextOnly)
                    return true
                } catch {
                    pasteStack = nil
                    throw error
                }
            }
            nextIndex += 1
        }
        pasteStack = nil
        return false
    }

    func cancelPasteStack() {
        pasteStack = nil
    }
}

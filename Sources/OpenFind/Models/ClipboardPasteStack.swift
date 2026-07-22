import Foundation

struct ClipboardPasteStack: Identifiable, Equatable, Sendable {
    let id: UUID
    let entryIDs: [UUID]
    var currentIndex: Int
    let plainTextOnly: Bool

    init(
        id: UUID = UUID(),
        entryIDs: [UUID],
        currentIndex: Int = 0,
        plainTextOnly: Bool = false
    ) {
        self.id = id
        self.entryIDs = entryIDs
        self.currentIndex = currentIndex
        self.plainTextOnly = plainTextOnly
    }

    var currentEntryID: UUID? {
        entryIDs.indices.contains(currentIndex) ? entryIDs[currentIndex] : nil
    }

    var totalCount: Int { entryIDs.count }

    var pastedCount: Int { min(totalCount, currentIndex) }

    var remainingCount: Int { max(0, totalCount - currentIndex) }
}

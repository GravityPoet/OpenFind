import Foundation

struct ClipboardDeletionUndo: Sendable {
    struct RemovedEntry: Sendable {
        let index: Int
        let entry: ClipboardEntry
    }

    let removedEntries: [RemovedEntry]
    let survivingEntryIDs: Set<UUID>
    let selectedEntryID: UUID?

    var count: Int { removedEntries.count }
}

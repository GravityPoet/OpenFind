import AppKit
import Foundation

extension ClipboardHistoryStore {
    static let foregroundPayloadCacheBudget = 48 * 1_024 * 1_024

    var residentPayloadBytes: Int {
        let entryBytes = entries.reduce(0) { partial, entry in
            partial + (entry.hasResidentPayload ? (entry.resolvedPayloadDescriptor?.byteCount ?? 0) : 0)
        }
        return entryBytes + materializedPayloadCacheBytes
    }

    func materializedEntry(for entry: ClipboardEntry) throws -> ClipboardEntry {
        guard let current = entries.first(where: { $0.id == entry.id }) else {
            throw ClipboardHistoryError.entryNotFound
        }
        guard nonresidentPayloadEntryIDs.contains(current.id) else {
            return current.synchronizingPayloadDescriptor()
        }
        if let cached = materializedPayloadCache[current.id] {
            touchMaterializedPayloadCache(current.id)
            return try current.restoringPayload(from: cached)
        }
        guard isPersistenceEnabled,
              !requiresPersistenceMigration,
              !isPersistenceDegraded,
              let stored = try persistence.loadEntry(id: current.id) else {
            throw ClipboardHistoryError.persistenceUnavailable
        }
        let materialized = try current.restoringPayload(from: stored)
        cacheMaterializedPayload(materialized)
        return materialized
    }

    func plainTextMaterializing(for entry: ClipboardEntry) throws -> String? {
        plainText(for: try materializedEntry(for: entry))
    }

    func hibernatePayloadsForBackground() {
        guard isPersistenceEnabled,
              !requiresPersistenceMigration,
              !isPersistenceDegraded,
              !hasUnpersistedPayloadChanges else { return }
        if hasUnpersistedChanges {
            // Metadata changes (pin, use count, OCR, deletion, notes) must be
            // durable before their payload is removed from memory. A failed
            // retry deliberately leaves the full payload resident.
            guard persist() else { return }
        }
        guard !hasUnpersistedChanges, !hasUnpersistedPayloadChanges else { return }
        isClipboardBackgroundResident = true
        pauseImageTextRecognitionForBackground()
        var summaries = entries
        for index in summaries.indices where summaries[index].hasResidentPayload {
            summaries[index] = summaries[index].strippingPayload()
            nonresidentPayloadEntryIDs.insert(summaries[index].id)
        }
        suppressEntryDirtyTracking = true
        entries = summaries
        suppressEntryDirtyTracking = false
        clearMaterializedPayloadCache()
        releasePresentationCachesForBackground()
        discardDeletionUndoForBackground()
        ProcessMemoryReclaimer.schedule()
    }

    func resumePayloadsForPresentation() {
        isClipboardBackgroundResident = false
        enqueueMissingImageTextRecognition()
    }

    func replacePayload(
        for id: UUID,
        with representations: [String: Data],
        pasteboardItems: [[String: Data]]? = nil
    ) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            throw ClipboardHistoryError.entryNotFound
        }
        var entry = entries[index]
        entry.representations = representations
        entry.pasteboardItems = pasteboardItems
        entry = entry.synchronizingPayloadDescriptor()
        guard entry.payloadDescriptor != nil else {
            throw ClipboardHistoryError.unsupportedContent
        }
        entries[index] = entry
        hasUnpersistedPayloadChanges = true
        nonresidentPayloadEntryIDs.remove(id)
        removeMaterializedPayloadFromCache(id)
    }

    private func cacheMaterializedPayload(_ entry: ClipboardEntry) {
        guard !isClipboardBackgroundResident,
              let byteCount = entry.resolvedPayloadDescriptor?.byteCount,
              byteCount <= Self.foregroundPayloadCacheBudget else { return }
        removeMaterializedPayloadFromCache(entry.id)
        while materializedPayloadCacheBytes + byteCount > Self.foregroundPayloadCacheBudget,
              let oldest = materializedPayloadCacheOrder.first {
            removeMaterializedPayloadFromCache(oldest)
        }
        materializedPayloadCache[entry.id] = entry
        materializedPayloadCacheOrder.append(entry.id)
        materializedPayloadCacheBytes += byteCount
    }

    private func touchMaterializedPayloadCache(_ id: UUID) {
        materializedPayloadCacheOrder.removeAll { $0 == id }
        materializedPayloadCacheOrder.append(id)
    }

    func removeMaterializedPayloadFromCache(_ id: UUID) {
        if let removed = materializedPayloadCache.removeValue(forKey: id) {
            materializedPayloadCacheBytes -= removed.resolvedPayloadDescriptor?.byteCount ?? 0
        }
        materializedPayloadCacheOrder.removeAll { $0 == id }
        materializedPayloadCacheBytes = max(0, materializedPayloadCacheBytes)
    }

    func clearMaterializedPayloadCache() {
        materializedPayloadCache.removeAll(keepingCapacity: false)
        materializedPayloadCacheOrder.removeAll(keepingCapacity: false)
        materializedPayloadCacheBytes = 0
    }
}

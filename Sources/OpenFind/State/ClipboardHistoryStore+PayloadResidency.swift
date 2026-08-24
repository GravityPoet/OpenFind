import AppKit
import Foundation

extension ClipboardHistoryStore {
    static let foregroundPayloadCacheBudget = 48 * 1_024 * 1_024
    /// Keep a bounded hot set while the app lives only in the menu bar. This
    /// avoids a SQLite/AES round trip for the clips people reach for most,
    /// while still dropping the large, cold part of clipboard history.
    static let backgroundPayloadRetentionBudget = 16 * 1_024 * 1_024
    static let backgroundPayloadRetentionItemLimit = 64
    static let backgroundPayloadRetentionItemByteLimit = 1 * 1_024 * 1_024
    /// Explicitly pinned or frequently used items may be richer (for example,
    /// a small image or formatted block) while sharing the same total budget.
    static let backgroundPayloadRetentionPriorityItemByteLimit = 4 * 1_024 * 1_024

    var residentPayloadBytes: Int {
        let entryBytes = entries.reduce(0) { partial, entry in
            partial + (entry.hasResidentPayload ? (payloadByteCount(for: entry) ?? 0) : 0)
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
        let referenceDate = Date()
        restoreSmallCachedPayloadsForBackground(at: referenceDate)
        let retainedIDs = retainedBackgroundPayloadIDs(at: referenceDate)
        var summaries = entries
        for index in summaries.indices where summaries[index].hasResidentPayload {
            guard !retainedIDs.contains(summaries[index].id) else {
                nonresidentPayloadEntryIDs.remove(summaries[index].id)
                continue
            }
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

    /// A materialized cold entry was already paid for by the user. If it is
    /// small enough to belong to the background hot set, put its payload back
    /// on the summary before trimming the rest of the history. This keeps a
    /// just-used item warm across a menu-bar-only transition.
    private func restoreSmallCachedPayloadsForBackground(at referenceDate: Date) {
        guard !materializedPayloadCache.isEmpty else { return }
        let cached = materializedPayloadCache
        suppressEntryDirtyTracking = true
        defer { suppressEntryDirtyTracking = false }
        for index in entries.indices {
            let entry = entries[index]
            guard !entry.hasResidentPayload,
                  let materialized = cached[entry.id],
                  let byteCount = payloadByteCount(for: materialized),
                  byteCount <= backgroundPayloadByteLimit(for: entry, at: referenceDate),
                  let restored = try? entry.restoringPayload(from: materialized) else {
                continue
            }
            entries[index] = restored
            nonresidentPayloadEntryIDs.remove(entry.id)
        }
    }

    private func retainedBackgroundPayloadIDs(at referenceDate: Date) -> Set<UUID> {
        let candidates = entries
            .filter { entry in
                guard entry.hasResidentPayload,
                      let byteCount = payloadByteCount(for: entry) else {
                    return false
                }
                return byteCount <= backgroundPayloadByteLimit(
                    for: entry,
                    at: referenceDate
                )
            }
            .sorted { lhs, rhs in
                let lhsTier = backgroundRetentionTier(lhs, at: referenceDate)
                let rhsTier = backgroundRetentionTier(rhs, at: referenceDate)
                if lhsTier != rhsTier { return lhsTier > rhsTier }

                let lhsActivity = max(lhs.lastUsedAt ?? .distantPast, lhs.createdAt)
                let rhsActivity = max(rhs.lastUsedAt ?? .distantPast, rhs.createdAt)
                if lhsActivity != rhsActivity { return lhsActivity > rhsActivity }

                let lhsScore = lhs.decayedUsageScore(at: referenceDate)
                let rhsScore = rhs.decayedUsageScore(at: referenceDate)
                if lhsScore != rhsScore { return lhsScore > rhsScore }
                return lhs.id.uuidString < rhs.id.uuidString
            }

        var retained = Set<UUID>()
        retained.reserveCapacity(min(
            candidates.count,
            Self.backgroundPayloadRetentionItemLimit
        ))
        var retainedBytes = 0
        for entry in candidates {
            guard retained.count < Self.backgroundPayloadRetentionItemLimit,
                  let byteCount = payloadByteCount(for: entry),
                  retainedBytes + byteCount <= Self.backgroundPayloadRetentionBudget else {
                continue
            }
            retained.insert(entry.id)
            retainedBytes += byteCount
        }
        return retained
    }

    private func payloadByteCount(for entry: ClipboardEntry) -> Int? {
        // Resident entries have a synchronized descriptor. Avoid rebuilding a
        // SHA-256 fingerprint over every payload while evaluating the hot set.
        entry.payloadDescriptor?.byteCount ?? entry.resolvedPayloadDescriptor?.byteCount
    }

    private func backgroundRetentionTier(
        _ entry: ClipboardEntry,
        at referenceDate: Date
    ) -> Int {
        if entry.isPinned || entry.frequentOverride == true { return 3 }
        if entry.frequentOverride == nil,
           entry.numberOfUses >= 3,
           entry.decayedUsageScore(at: referenceDate) >= 1.5 {
            return 2
        }
        return 1
    }

    private func backgroundPayloadByteLimit(
        for entry: ClipboardEntry,
        at referenceDate: Date
    ) -> Int {
        backgroundRetentionTier(entry, at: referenceDate) >= 2
            ? Self.backgroundPayloadRetentionPriorityItemByteLimit
            : Self.backgroundPayloadRetentionItemByteLimit
    }

    func resumePayloadsForForeground() {
        isClipboardBackgroundResident = false
    }

    func resumePayloadsForPresentation() {
        resumePayloadsForForeground()
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
              let byteCount = payloadByteCount(for: entry),
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
            materializedPayloadCacheBytes -= payloadByteCount(for: removed) ?? 0
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

import Foundation

extension ClipboardHistoryStore {
    func setPersistenceEnabled(_ enabled: Bool) {
        isPersistenceEnabled = enabled
        defaults.set(enabled, forKey: Self.persistenceEnabledKey)
        guard !enabled else {
            requiresPersistenceMigration = persistence.requiresExplicitMigration
            persist()
            return
        }
        do {
            try persistence.remove()
            requiresPersistenceMigration = false
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func migratePersistence() -> Bool {
        guard isPersistenceEnabled, requiresPersistenceMigration else { return true }
        do {
            entries = Array(try persistence.load().prefix(Self.maximumEntries))
            let trimmed = trimToLimits()
            let normalizedPins = normalizePinnedKeys()
            selectedIndex = 0
            requiresPersistenceMigration = false
            lastErrorMessage = nil
            if trimmed || normalizedPins { persist() }
            return true
        } catch {
            lastErrorMessage = error.localizedDescription
            return false
        }
    }

    func persist() {
        guard isPersistenceEnabled, !requiresPersistenceMigration else { return }
        do {
            try persistence.save(entries)
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func trimToLimits(referenceDate: Date = Date()) -> Bool {
        let initialCount = entries.count
        if let cutoff = retentionPeriod.cutoff(referenceDate: referenceDate) {
            entries.removeAll { !$0.isPinned && $0.createdAt < cutoff }
        }
        var payloadBytes = retainedPayloadBytes
        while entries.count > Self.maximumEntries || payloadBytes > Self.maximumHistoryBytes {
            guard let index = entries.lastIndex(where: { !$0.isPinned })
                ?? entries.indices.last else { break }
            payloadBytes -= payloadByteCount(of: entries[index])
            entries.remove(at: index)
        }
        return entries.count != initialCount
    }

    var retainedPayloadBytes: Int {
        entries.reduce(0) { $0 + payloadByteCount(of: $1) }
    }

    private func payloadByteCount(of entry: ClipboardEntry) -> Int {
        entry.retainedPasteboardItems
            .flatMap(\.values)
            .reduce(0) { $0 + $1.count }
    }
}

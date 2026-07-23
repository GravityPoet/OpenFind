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
            entries = try persistence.load()
            let trimmed = trimToLimits()
            let normalizedPins = normalizePinnedKeys()
            selectedIndex = 0
            requiresPersistenceMigration = false
            lastErrorMessage = nil
            if trimmed || normalizedPins { persist() }
            enqueueMissingImageTextRecognition()
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
        return entries.count != initialCount
    }

    @discardableResult
    func pruneExpiredHistory(referenceDate: Date = Date()) -> Bool {
        guard !isPanelPresented, trimToLimits(referenceDate: referenceDate) else {
            return false
        }
        selectedIndex = min(selectedIndex, max(0, filteredEntries.count - 1))
        persist()
        return true
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

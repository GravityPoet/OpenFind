import Foundation

extension ClipboardHistoryStore {
    func setPersistenceEnabled(_ enabled: Bool) {
        guard !enabled else {
            isPersistenceEnabled = true
            defaults.set(true, forKey: Self.persistenceEnabledKey)
            requiresPersistenceMigration = persistence.requiresExplicitMigration
            persist()
            return
        }
        do {
            // Keep the persisted preference enabled until the durable delete
            // succeeds, otherwise a failed delete is silently skipped on the
            // next launch while ciphertext remains on disk.
            try persistence.remove()
            isPersistenceEnabled = false
            defaults.set(false, forKey: Self.persistenceEnabledKey)
            requiresPersistenceMigration = false
            lastErrorMessage = nil
        } catch {
            isPersistenceEnabled = true
            defaults.set(true, forKey: Self.persistenceEnabledKey)
            lastErrorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func migratePersistence() -> Bool {
        guard isPersistenceEnabled, requiresPersistenceMigration else { return true }
        do {
            entries = try persistence.load()
            let trimmed = trimToLimits()
            let normalizedKinds = normalizeContentKinds()
            let normalizedPins = normalizePinnedKeys()
            selectedIndex = 0
            requiresPersistenceMigration = false
            lastErrorMessage = nil
            if trimmed || normalizedKinds || normalizedPins { persist() }
            enqueueMissingImageTextRecognition()
            return true
        } catch {
            lastErrorMessage = error.localizedDescription
            return false
        }
    }

    func persist() {
        guard isPersistenceEnabled, !requiresPersistenceMigration else { return }
        guard !isPersistenceDegraded else {
            lastErrorMessage = ClipboardHistoryError
                .persistenceDesynchronized.localizedDescription
            return
        }
        do {
            try persistence.save(entries)
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func normalizeContentKinds() -> Bool {
        var changed = false
        for index in entries.indices {
            let resolved = ClipboardEntryKind.resolvingStandaloneURL(
                entries[index].kind,
                previewText: entries[index].previewText
            )
            guard resolved != entries[index].kind else { continue }
            entries[index].kind = resolved
            changed = true
        }
        return changed
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

import AppKit

extension ClipboardHistoryStore {
    func configurationSnippets() throws -> [ClipboardSnippetRecord] {
        try reusableEntries.filter { $0.kind == .text }.compactMap { entry in
            let materialized = try materializedEntry(for: entry)
            guard let content = plainText(for: materialized) else { return nil }
            return ClipboardSnippetRecord(id: entry.id, name: entry.displayTitle, content: content,
                                          keyword: entry.snippetKeyword, collection: entry.snippetCollection,
                                          expandsAutomatically: entry.expandsFromKeyword)
        }.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    func validatedConfigurationSnippets(_ records: [ClipboardSnippetRecord]) throws -> [ClipboardSnippetRecord] {
        guard records.count <= Self.maximumSnippetCount else { throw ClipboardSnippetError.tooManySnippets }
        let validated = try records.map { try validatedSnippetRecord($0, maximumBytes: Self.maximumItemBytes) }
        guard Set(validated.map(\.id)).count == validated.count else { throw ClipboardSnippetError.duplicateIdentifiers }
        let keywords = validated.compactMap(\.keyword).map(\.localizedLowercase)
        guard Set(keywords).count == keywords.count else { throw ClipboardSnippetError.duplicateKeyword }
        return validated
    }

    func replaceConfigurationSnippets(_ records: [ClipboardSnippetRecord]) throws {
        let records = try validatedConfigurationSnippets(records)
        let previous = try configurationSnippets()
        if previous == records.sorted(by: { $0.id.uuidString < $1.id.uuidString }) { return }
        let managed = Set(previous.map(\.id))
        let retained = entries.filter { !managed.contains($0.id) }
        guard !records.contains(where: { record in retained.contains { $0.id == record.id } }) else {
            throw ClipboardSnippetError.duplicateIdentifiers
        }
        let previousEntries = entries
        let previousNonresident = nonresidentPayloadEntryIDs
        let previousDirty = hasUnpersistedChanges
        let previousPayloadDirty = hasUnpersistedPayloadChanges
        var next = retained
        for record in records {
            var entry = snippetEntry(from: record, existingEntries: next)
            if let old = previousEntries.first(where: { $0.id == record.id }) {
                // Unchanged snippets keep all local provenance and native
                // representations; only actual edits replace their payload.
                if previous.first(where: { $0.id == record.id }) == record {
                    next.append(old)
                    continue
                }
                entry.pinKey = old.pinKey
                entry.createdAt = old.createdAt
                entry.firstCopiedAt = old.firstCopiedAt
                entry.copyCount = old.copyCount
            }
            next.append(entry)
        }
        entries = next
        _ = normalizePinnedKeys()
        let changedIDs = records.filter { record in previous.first { $0.id == record.id } != record }.map(\.id)
        nonresidentPayloadEntryIDs.formIntersection(Set(next.map(\.id)))
        nonresidentPayloadEntryIDs.subtract(changedIDs)
        clearMaterializedPayloadCache()
        hasUnpersistedPayloadChanges = true
        guard persist() else {
            entries = previousEntries
            nonresidentPayloadEntryIDs = previousNonresident
            hasUnpersistedChanges = previousDirty
            hasUnpersistedPayloadChanges = previousPayloadDirty
            throw ConfigurationError.saveFailed
        }
        selectedIndex = 0
        clearMultiSelection()
    }
}

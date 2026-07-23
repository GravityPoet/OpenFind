import AppKit
import Foundation

extension ClipboardHistoryStore {
    static let maximumSnippetArchiveBytes = 20 * 1_024 * 1_024
    static let maximumSnippetCount = 10_000
    static let maximumSnippetNameLength = 256
    static let maximumSnippetCharacters = 100_000
    static let maximumSnippetKeywordLength = 64
    static let maximumSnippetCollectionLength = 128

    var reusableEntries: [ClipboardEntry] {
        entries.filter(\.isPinned).sorted {
            let lhsCollection = $0.snippetCollection ?? ""
            let rhsCollection = $1.snippetCollection ?? ""
            if lhsCollection.localizedCaseInsensitiveCompare(rhsCollection) != .orderedSame {
                return lhsCollection.localizedCaseInsensitiveCompare(rhsCollection) == .orderedAscending
            }
            return $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending
        }
    }

    var snippetCollectionNames: [String] {
        Array(Set(entries.compactMap { $0.isPinned ? $0.snippetCollection : nil })).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    func snippetEntry(matchingSuffix buffer: String) -> ClipboardEntry? {
        _ = filteredEntries
        let normalized = buffer.localizedLowercase
        guard let candidate = cachedSnippetKeywords.first(where: {
            normalized.hasSuffix($0.keyword)
        }) else { return nil }
        return cachedEntryByID[candidate.id]
    }

    @discardableResult
    func createSnippet(
        name: String,
        content: String,
        keyword: String? = nil,
        collection: String? = nil,
        expandsAutomatically: Bool = false
    ) throws -> ClipboardEntry {
        let record = try validatedSnippetRecord(ClipboardSnippetRecord(
            id: UUID(),
            name: name,
            content: content,
            keyword: keyword,
            collection: collection,
            expandsAutomatically: expandsAutomatically
        ))
        try ensureKeywordIsAvailable(record.keyword, excluding: nil)
        let entry = snippetEntry(from: record, existingEntries: entries)
        entries.insert(entry, at: 0)
        restoreSelection(id: entry.id)
        persist()
        return entry
    }

    func configureSnippet(
        _ entry: ClipboardEntry,
        name: String,
        content: String? = nil,
        keyword: String?,
        collection: String?,
        expandsAutomatically: Bool
    ) throws {
        guard let index = entries.firstIndex(where: { $0.id == entry.id && $0.isPinned }),
              plainText(for: entries[index]) != nil else {
            throw ClipboardSnippetError.textOnly
        }
        let content = content ?? plainText(for: entries[index]) ?? ""
        let record = try validatedSnippetRecord(ClipboardSnippetRecord(
            id: entry.id,
            name: name,
            content: content,
            keyword: keyword,
            collection: collection,
            expandsAutomatically: expandsAutomatically
        ))
        try ensureKeywordIsAvailable(record.keyword, excluding: entry.id)
        entries[index].customTitle = record.name
        entries[index].representations = [
            NSPasteboard.PasteboardType.string.rawValue: Data(record.content.utf8),
        ]
        entries[index].pasteboardItems = nil
        entries[index].previewText = String(record.content.prefix(4_096))
        entries[index].kind = .text
        entries[index].snippetKeyword = record.keyword
        entries[index].snippetCollection = record.collection
        entries[index].snippetExpansionEnabled = record.expandsAutomatically
            && record.keyword != nil
        persist()
    }

    func exportSnippetArchive() throws -> Data {
        let snippets = reusableEntries.compactMap { entry -> ClipboardSnippetRecord? in
            guard let content = plainText(for: entry) else { return nil }
            return ClipboardSnippetRecord(
                id: entry.id,
                name: entry.displayTitle,
                content: content,
                keyword: entry.snippetKeyword,
                collection: entry.snippetCollection,
                expandsAutomatically: entry.expandsFromKeyword
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(ClipboardSnippetArchive(snippets: snippets))
    }

    @discardableResult
    func importSnippetArchive(_ data: Data) throws -> Int {
        guard data.count <= Self.maximumSnippetArchiveBytes else {
            throw ClipboardSnippetError.archiveTooLarge
        }
        let archive: ClipboardSnippetArchive
        do {
            archive = try JSONDecoder().decode(ClipboardSnippetArchive.self, from: data)
        } catch {
            throw ClipboardSnippetError.unsupportedArchiveVersion
        }
        guard archive.version == ClipboardSnippetArchive.currentVersion else {
            throw ClipboardSnippetError.unsupportedArchiveVersion
        }
        guard archive.snippets.count <= Self.maximumSnippetCount else {
            throw ClipboardSnippetError.tooManySnippets
        }
        let records = try archive.snippets.map(validatedSnippetRecord)
        guard Set(records.map(\.id)).count == records.count else {
            throw ClipboardSnippetError.duplicateIdentifiers
        }
        let importedKeywords = records.compactMap(\.keyword).map(\.localizedLowercase)
        guard Set(importedKeywords).count == importedKeywords.count else {
            throw ClipboardSnippetError.duplicateKeyword
        }

        var next = entries
        let importedIDs = Set(records.map(\.id))
        let existingKeywords = Set(
            next.compactMap { entry -> String? in
                guard !importedIDs.contains(entry.id),
                      let keyword = entry.snippetKeyword?.localizedLowercase else { return nil }
                return keyword
            }
        )
        guard importedKeywords.allSatisfy({ !existingKeywords.contains($0) }) else {
            throw ClipboardSnippetError.duplicateKeyword
        }

        for record in records {
            if let index = next.firstIndex(where: { $0.id == record.id && $0.isPinned }) {
                // Import updates content metadata in place. Preserve the
                // existing pin key, copy statistics, origin, and timestamps.
                next[index].customTitle = record.name
                next[index].representations = [
                    NSPasteboard.PasteboardType.string.rawValue: Data(record.content.utf8),
                ]
                next[index].pasteboardItems = nil
                next[index].previewText = String(record.content.prefix(4_096))
                next[index].kind = .text
                next[index].snippetCollection = record.collection
                next[index].snippetKeyword = record.keyword
                next[index].snippetExpansionEnabled = record.expandsAutomatically
                    && record.keyword != nil
            } else {
                var record = record
                if next.contains(where: { $0.id == record.id }) {
                    record.id = UUID()
                }
                next.insert(snippetEntry(from: record, existingEntries: next), at: 0)
            }
        }
        entries = next
        selectedIndex = 0
        clearMultiSelection()
        persist()
        return records.count
    }

    private func snippetEntry(
        from record: ClipboardSnippetRecord,
        existingEntries: [ClipboardEntry]
    ) -> ClipboardEntry {
        let data = Data(record.content.utf8)
        return ClipboardEntry(
            id: record.id,
            previewText: String(record.content.prefix(4_096)),
            kind: .text,
            representations: [NSPasteboard.PasteboardType.string.rawValue: data],
            isPinned: true,
            pinKey: ClipboardPinKey.available(in: existingEntries).first,
            customTitle: record.name,
            firstCopiedAt: Date(),
            copyCount: 1,
            snippetCollection: record.collection,
            snippetKeyword: record.keyword,
            snippetExpansionEnabled: record.expandsAutomatically && record.keyword != nil
        )
    }

    private func validatedSnippetRecord(
        _ record: ClipboardSnippetRecord
    ) throws -> ClipboardSnippetRecord {
        guard let name = normalizedMetadata(
            record.name,
            limit: Self.maximumSnippetNameLength
        ) else {
            throw ClipboardSnippetError.invalidName
        }
        guard record.content.count <= Self.maximumSnippetCharacters,
              Data(record.content.utf8).count <= itemLimitBytes else {
            throw ClipboardSnippetError.invalidContent
        }
        let keyword = try normalizedSnippetKeyword(record.keyword)
        let collection = try normalizedSnippetCollection(record.collection)
        return ClipboardSnippetRecord(
            id: record.id,
            name: name,
            content: record.content,
            keyword: keyword,
            collection: collection,
            expandsAutomatically: record.expandsAutomatically && keyword != nil
        )
    }

    private func normalizedSnippetKeyword(_ value: String?) throws -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty { return nil }
        guard normalized.count <= Self.maximumSnippetKeywordLength,
              normalized.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            throw ClipboardSnippetError.invalidKeyword
        }
        return normalized
    }

    private func normalizedSnippetCollection(_ value: String?) throws -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty { return nil }
        guard normalized.count <= Self.maximumSnippetCollectionLength,
              normalized.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            throw ClipboardSnippetError.invalidCollection
        }
        return normalized
    }

    private func ensureKeywordIsAvailable(_ keyword: String?, excluding id: UUID?) throws {
        guard let keyword else { return }
        let normalized = keyword.localizedLowercase
        guard !entries.contains(where: {
            $0.id != id && $0.snippetKeyword?.localizedLowercase == normalized
        }) else {
            throw ClipboardSnippetError.duplicateKeyword
        }
    }
}

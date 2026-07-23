import Foundation

extension ClipboardHistoryStore {
    var filteredEntries: [ClipboardEntry] {
        let revision = clipboardProjectionRevision
        if cachedClipboardProjectionRevision != revision {
            rebuildClipboardProjection(revision: revision)
        }
        return cachedFilteredEntries
    }

    func visibleIndex(for entry: ClipboardEntry) -> Int? {
        visibleIndex(for: entry.id)
    }

    func visibleIndex(for id: UUID) -> Int? {
        _ = filteredEntries
        return cachedVisibleIndexByID[id]
    }

    func quickIndex(for entry: ClipboardEntry) -> Int? {
        _ = filteredEntries
        return cachedQuickIndexByID[entry.id]
    }

    func quickEntry(at index: Int) -> ClipboardEntry? {
        _ = filteredEntries
        guard cachedQuickEntryIDs.indices.contains(index),
              let visibleIndex = cachedVisibleIndexByID[cachedQuickEntryIDs[index]],
              cachedFilteredEntries.indices.contains(visibleIndex) else { return nil }
        return cachedFilteredEntries[visibleIndex]
    }

    func pinnedEntry(for key: String) -> ClipboardEntry? {
        filteredEntries.first {
            $0.isPinned && ClipboardPinKey.normalize($0.pinKey) == key
        }
    }

    private func rebuildClipboardProjection(revision: UInt64) {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let sorted = sortedEntries
        let filtered: [ClipboardEntry]
        if search.isEmpty {
            filtered = sorted
        } else {
            switch preferences.searchMode {
            case .exact:
                filtered = exactMatches(search, within: sorted)
            case .fuzzy:
                filtered = fuzzyMatches(search, within: sorted)
            case .regularExpression:
                filtered = regularExpressionMatches(search, within: sorted)
            case .mixed:
                let exact = exactMatches(search, within: sorted)
                if !exact.isEmpty {
                    filtered = exact
                } else {
                    let regularExpression = regularExpressionMatches(search, within: sorted)
                    filtered = regularExpression.isEmpty
                        ? fuzzyMatches(search, within: sorted)
                        : regularExpression
                }
            }
        }
        cachedFilteredEntries = filtered
        cachedVisibleIndexByID = Dictionary(
            uniqueKeysWithValues: filtered.enumerated().map { ($0.element.id, $0.offset) }
        )
        cachedEntryByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        cachedSnippetKeywords = entries.compactMap { entry in
            guard entry.expandsFromKeyword,
                  let keyword = entry.snippetKeyword?.localizedLowercase else { return nil }
            return (keyword, entry.id)
        }.sorted {
            if $0.keyword.count != $1.keyword.count {
                return $0.keyword.count > $1.keyword.count
            }
            return $0.keyword < $1.keyword
        }
        let quickEntries = filtered.lazy.filter { !$0.isPinned }.prefix(9)
        cachedQuickEntryIDs = quickEntries.map(\.id)
        cachedQuickIndexByID = Dictionary(
            uniqueKeysWithValues: cachedQuickEntryIDs.enumerated().map {
                ($0.element, $0.offset + 1)
            }
        )
        cachedClipboardProjectionRevision = revision
        clipboardProjectionBuildCount &+= 1
    }

    var selectedEntry: ClipboardEntry? {
        let visible = filteredEntries
        guard visible.indices.contains(selectedIndex) else { return nil }
        return visible[selectedIndex]
    }

    func select(_ entry: ClipboardEntry, preservingMultiSelection: Bool = false) {
        guard let index = visibleIndex(for: entry) else { return }
        if !preservingMultiSelection { clearMultiSelection() }
        selectedIndex = index
    }

    func moveSelection(by offset: Int) {
        clearMultiSelection()
        guard !filteredEntries.isEmpty else {
            selectedIndex = 0
            return
        }
        selectedIndex = min(filteredEntries.count - 1, max(0, selectedIndex + offset))
    }

    func restoreSelection(id: UUID?) {
        guard let id, let index = visibleIndex(for: id) else {
            selectedIndex = min(selectedIndex, max(0, filteredEntries.count - 1))
            return
        }
        selectedIndex = index
    }

    func rawSearchableText(for entry: ClipboardEntry) -> String {
        [
            entry.displayTitle,
            entry.customTitle == nil ? nil : entry.previewText,
            entry.sourceApplicationName,
            entry.sourceBundleIdentifier,
            entry.snippetKeyword,
            entry.snippetCollection,
        ]
            .compactMap { $0 }
            .joined(separator: "\n")
    }

    private var sortedEntries: [ClipboardEntry] {
        entries.sorted { lhs, rhs in
            let lhsRank = pinRank(for: lhs)
            let rhsRank = pinRank(for: rhs)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            let lhsDate = preferences.sortMode == .lastCopied
                ? lhs.createdAt : lhs.initialCopiedAt
            let rhsDate = preferences.sortMode == .lastCopied
                ? rhs.createdAt : rhs.initialCopiedAt
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private func pinRank(for entry: ClipboardEntry) -> Int {
        switch preferences.pinsPosition {
        case .top: entry.isPinned ? 0 : 1
        case .bottom: entry.isPinned ? 1 : 0
        }
    }

    private func exactMatches(
        _ query: String,
        within entries: [ClipboardEntry]
    ) -> [ClipboardEntry] {
        entries.filter {
            ClipboardSearchEngine.match(
                query: query,
                in: rawSearchableText(for: $0),
                mode: .exact
            ) != nil
        }
    }

    private func regularExpressionMatches(
        _ query: String,
        within entries: [ClipboardEntry]
    ) -> [ClipboardEntry] {
        entries.filter {
            ClipboardSearchEngine.match(
                query: query,
                in: rawSearchableText(for: $0),
                mode: .regularExpression
            ) != nil
        }
    }

    private func fuzzyMatches(
        _ query: String,
        within entries: [ClipboardEntry]
    ) -> [ClipboardEntry] {
        entries.compactMap { entry -> (ClipboardEntry, Int)? in
            guard let match = ClipboardSearchEngine.match(
                query: query,
                in: rawSearchableText(for: entry),
                mode: .fuzzy
            ) else { return nil }
            return (entry, match.score)
        }.sorted { lhs, rhs in
            let lhsRank = pinRank(for: lhs.0)
            let rhsRank = pinRank(for: rhs.0)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0.createdAt > rhs.0.createdAt
        }.map(\.0)
    }
}

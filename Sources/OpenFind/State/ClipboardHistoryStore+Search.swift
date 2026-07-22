import Foundation

extension ClipboardHistoryStore {
    var filteredEntries: [ClipboardEntry] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let sorted = sortedEntries
        guard !search.isEmpty else { return sorted }
        switch preferences.searchMode {
        case .exact:
            return exactMatches(search, within: sorted)
        case .fuzzy:
            return fuzzyMatches(search, within: sorted)
        case .regularExpression:
            return regularExpressionMatches(search, within: sorted)
        case .mixed:
            let exact = exactMatches(search, within: sorted)
            if !exact.isEmpty { return exact }
            let regularExpression = regularExpressionMatches(search, within: sorted)
            return regularExpression.isEmpty
                ? fuzzyMatches(search, within: sorted)
                : regularExpression
        }
    }

    var selectedEntry: ClipboardEntry? {
        let visible = filteredEntries
        guard visible.indices.contains(selectedIndex) else { return nil }
        return visible[selectedIndex]
    }

    func select(_ entry: ClipboardEntry, preservingMultiSelection: Bool = false) {
        guard let index = filteredEntries.firstIndex(where: { $0.id == entry.id }) else { return }
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
        guard let id,
              let index = filteredEntries.firstIndex(where: { $0.id == id }) else {
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

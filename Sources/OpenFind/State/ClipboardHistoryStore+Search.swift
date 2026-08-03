import Foundation

enum ClipboardSearchMatchField: Equatable, Sendable {
    case title
    case content
    case recognizedText
    case sourceApplication
    case snippetKeyword
    case snippetCollection

    var localizedLabel: String {
        switch self {
        case .title: L("Clipboard Search Match Note")
        case .content: L("Clipboard Search Match Content")
        case .recognizedText: L("Clipboard Search Match Image Text")
        case .sourceApplication: L("Clipboard Search Match Source")
        case .snippetKeyword: L("Clipboard Search Match Keyword")
        case .snippetCollection: L("Clipboard Search Match Collection")
        }
    }
}

struct ClipboardSearchPresentation: Equatable, Sendable {
    let field: ClipboardSearchMatchField
    let context: String?
}

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

    func searchPresentation(for entry: ClipboardEntry) -> ClipboardSearchPresentation? {
        _ = filteredEntries
        return cachedSearchPresentationByID[entry.id]
    }

    func isFrequentlyUsed(_ entry: ClipboardEntry, at referenceDate: Date? = nil) -> Bool {
        if let referenceDate {
            return qualifiesAsFrequentlyUsed(entry, at: referenceDate)
        }
        _ = filteredEntries
        return cachedFrequentEntryIDs.contains(entry.id)
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
        let referenceDate = Date()
        let frequentEntryIDs = frequentEntryIDs(at: referenceDate)
        cachedFrequentEntryIDs = frequentEntryIDs
        cachedUsageRankingDate = referenceDate
        let structuredQuery = ClipboardStructuredQuery.parse(query)
        let search = structuredQuery.text
        let baseEntries = sortedEntries(
            at: referenceDate,
            frequentEntryIDs: frequentEntryIDs
        )
        let kindFiltered = kindFilter == .all
            ? baseEntries
            : baseEntries.filter { kindFilter.matches($0.kind) }
        let sorted = kindFiltered.filter(structuredQuery.matches)
        let ranked: [ClipboardRankedSearchResult]
        if search.isEmpty {
            ranked = sorted.enumerated().map {
                ClipboardRankedSearchResult(
                    entry: $0.element,
                    presentation: nil,
                    rank: nil,
                    fallbackIndex: $0.offset
                )
            }
        } else {
            switch preferences.searchMode {
            case .exact:
                ranked = rankedMatches(
                    search,
                    mode: .exact,
                    within: sorted,
                    referenceDate: referenceDate
                )
            case .fuzzy:
                ranked = rankedMatches(
                    search,
                    mode: .fuzzy,
                    within: sorted,
                    referenceDate: referenceDate
                )
            case .regularExpression:
                ranked = rankedMatches(
                    search,
                    mode: .regularExpression,
                    within: sorted,
                    referenceDate: referenceDate
                )
            case .mixed:
                let exact = rankedMatches(
                    search,
                    mode: .exact,
                    within: sorted,
                    referenceDate: referenceDate
                )
                if !exact.isEmpty {
                    ranked = exact
                } else {
                    let regularExpression = rankedMatches(
                        search,
                        mode: .regularExpression,
                        within: sorted,
                        referenceDate: referenceDate
                    )
                    ranked = regularExpression.isEmpty
                        ? rankedMatches(
                            search,
                            mode: .fuzzy,
                            within: sorted,
                            referenceDate: referenceDate
                        )
                        : regularExpression
                }
            }
        }
        let filtered = ranked.map(\.entry)
        cachedFilteredEntries = filtered
        cachedHighlightQuery = search
        cachedSearchPresentationByID = Dictionary(
            uniqueKeysWithValues: ranked.compactMap { result in
                result.presentation.map { (result.entry.id, $0) }
            }
        )
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
            preferences.imageTextRecognitionEnabled ? entry.recognizedText : nil,
            entry.snippetKeyword,
            entry.snippetCollection,
        ]
            .compactMap { $0 }
            .joined(separator: "\n")
    }

    private func sortedEntries(
        at referenceDate: Date,
        frequentEntryIDs: Set<UUID>
    ) -> [ClipboardEntry] {
        entries.sorted { lhs, rhs in
            let lhsRank = browseRank(for: lhs, frequentEntryIDs: frequentEntryIDs)
            let rhsRank = browseRank(for: rhs, frequentEntryIDs: frequentEntryIDs)
            if lhsRank != rhsRank { return lhsRank < rhsRank }

            if frequentEntryIDs.contains(lhs.id), frequentEntryIDs.contains(rhs.id) {
                let lhsScore = lhs.decayedUsageScore(at: referenceDate)
                let rhsScore = rhs.decayedUsageScore(at: referenceDate)
                if lhsScore != rhsScore { return lhsScore > rhsScore }
                if lhs.lastUsedAt != rhs.lastUsedAt {
                    return (lhs.lastUsedAt ?? .distantPast) > (rhs.lastUsedAt ?? .distantPast)
                }
            }

            let lhsDate = copiedDate(for: lhs)
            let rhsDate = copiedDate(for: rhs)
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            if lhs.numberOfCopies != rhs.numberOfCopies {
                return lhs.numberOfCopies > rhs.numberOfCopies
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private func copiedDate(for entry: ClipboardEntry) -> Date {
        preferences.sortMode == .lastCopied
            ? entry.createdAt
            : entry.initialCopiedAt
    }

    private func frequentEntryIDs(at referenceDate: Date) -> Set<UUID> {
        let candidates = entries.filter {
            !$0.isPinned && qualifiesAsFrequentlyUsed($0, at: referenceDate)
        }.sorted { lhs, rhs in
            let lhsScore = lhs.decayedUsageScore(at: referenceDate)
            let rhsScore = rhs.decayedUsageScore(at: referenceDate)
            if lhsScore != rhsScore { return lhsScore > rhsScore }
            if lhs.lastUsedAt != rhs.lastUsedAt {
                return (lhs.lastUsedAt ?? .distantPast) > (rhs.lastUsedAt ?? .distantPast)
            }
            return copiedDate(for: lhs) > copiedDate(for: rhs)
        }
        return Set(candidates.prefix(5).map(\.id))
    }

    private func qualifiesAsFrequentlyUsed(
        _ entry: ClipboardEntry,
        at referenceDate: Date
    ) -> Bool {
        !entry.isPinned
            && entry.numberOfUses >= 3
            && entry.decayedUsageScore(at: referenceDate) >= 1.5
    }

    private func browseRank(
        for entry: ClipboardEntry,
        frequentEntryIDs: Set<UUID>
    ) -> Int {
        switch preferences.pinsPosition {
        case .top:
            if entry.isPinned { return 0 }
            return frequentEntryIDs.contains(entry.id) ? 1 : 2
        case .bottom:
            if entry.isPinned { return 2 }
            return frequentEntryIDs.contains(entry.id) ? 0 : 1
        }
    }

    private func pinRank(for entry: ClipboardEntry) -> Int {
        switch preferences.pinsPosition {
        case .top: entry.isPinned ? 0 : 1
        case .bottom: entry.isPinned ? 1 : 0
        }
    }

    private func rankedMatches(
        _ query: String,
        mode: ClipboardSearchMode,
        within entries: [ClipboardEntry],
        referenceDate: Date
    ) -> [ClipboardRankedSearchResult] {
        entries.enumerated().compactMap { index, entry in
            guard let best = bestMatch(
                for: entry,
                query: query,
                mode: mode,
                referenceDate: referenceDate
            ) else {
                return nil
            }
            return ClipboardRankedSearchResult(
                entry: entry,
                presentation: ClipboardSearchPresentation(
                    field: best.candidate.field,
                    context: matchContext(
                        for: entry,
                        candidate: best.candidate,
                        range: best.range
                    )
                ),
                rank: best.rank,
                fallbackIndex: index
            )
        }.sorted { lhs, rhs in
            let lhsPinRank = pinRank(for: lhs.entry)
            let rhsPinRank = pinRank(for: rhs.entry)
            if lhsPinRank != rhsPinRank { return lhsPinRank < rhsPinRank }
            guard let lhsRank = lhs.rank, let rhsRank = rhs.rank else {
                return lhs.fallbackIndex < rhs.fallbackIndex
            }
            if lhsRank != rhsRank { return lhsRank.isPreferred(over: rhsRank) }
            return lhs.fallbackIndex < rhs.fallbackIndex
        }
    }

    private func bestMatch(
        for entry: ClipboardEntry,
        query: String,
        mode: ClipboardSearchMode,
        referenceDate: Date
    ) -> ClipboardRankedCandidate? {
        searchCandidates(for: entry).compactMap { candidate in
            guard let match = ClipboardSearchEngine.match(
                query: query,
                in: candidate.text,
                mode: mode
            ), let range = preferredRange(in: candidate.text, ranges: match.ranges) else {
                return nil
            }
            return ClipboardRankedCandidate(
                candidate: candidate,
                range: range,
                rank: ClipboardSearchRelevance(
                    fieldPriority: candidate.fieldPriority,
                    quality: matchQuality(
                        in: candidate.text,
                        range: range,
                        mode: mode
                    ),
                    fuzzyScore: match.score,
                    usageScore: entry.decayedUsageScore(at: referenceDate),
                    copiedDate: copiedDate(for: entry),
                    copyCount: entry.numberOfCopies,
                    position: candidate.text.distance(
                        from: candidate.text.startIndex,
                        to: range.lowerBound
                    ),
                    candidateLength: candidate.text.count
                )
            )
        }.max { lhs, rhs in
            rhs.rank.isPreferred(over: lhs.rank)
        }
    }

    private func searchCandidates(for entry: ClipboardEntry) -> [ClipboardSearchCandidate] {
        var candidates: [ClipboardSearchCandidate] = []
        if entry.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            candidates.append(ClipboardSearchCandidate(
                text: entry.displayTitle,
                field: .title,
                fieldPriority: 6
            ))
        }
        candidates.append(ClipboardSearchCandidate(
            text: entry.previewText,
            field: .content,
            fieldPriority: 5
        ))
        if let keyword = entry.snippetKeyword, !keyword.isEmpty {
            candidates.append(ClipboardSearchCandidate(
                text: keyword,
                field: .snippetKeyword,
                fieldPriority: 5
            ))
        }
        if preferences.imageTextRecognitionEnabled,
           let recognizedText = entry.recognizedText,
           !recognizedText.isEmpty {
            candidates.append(ClipboardSearchCandidate(
                text: recognizedText,
                field: .recognizedText,
                fieldPriority: 4
            ))
        }
        if let collection = entry.snippetCollection, !collection.isEmpty {
            candidates.append(ClipboardSearchCandidate(
                text: collection,
                field: .snippetCollection,
                fieldPriority: 3
            ))
        }
        if let applicationName = entry.sourceApplicationName, !applicationName.isEmpty {
            candidates.append(ClipboardSearchCandidate(
                text: applicationName,
                field: .sourceApplication,
                fieldPriority: 2
            ))
        }
        if let bundleIdentifier = entry.sourceBundleIdentifier, !bundleIdentifier.isEmpty {
            candidates.append(ClipboardSearchCandidate(
                text: bundleIdentifier,
                field: .sourceApplication,
                fieldPriority: 1
            ))
        }
        return candidates
    }

    private func preferredRange(
        in candidate: String,
        ranges: [Range<String.Index>]
    ) -> Range<String.Index>? {
        ranges.min { lhs, rhs in
            let lhsIsWord = isWholeWord(lhs, in: candidate)
            let rhsIsWord = isWholeWord(rhs, in: candidate)
            if lhsIsWord != rhsIsWord { return lhsIsWord }
            return lhs.lowerBound < rhs.lowerBound
        }
    }

    private func matchQuality(
        in candidate: String,
        range: Range<String.Index>,
        mode: ClipboardSearchMode
    ) -> Int {
        if mode == .fuzzy { return 0 }
        if range.lowerBound == candidate.startIndex,
           range.upperBound == candidate.endIndex { return 4 }
        if range.lowerBound == candidate.startIndex { return 3 }
        return isWholeWord(range, in: candidate) ? 2 : 1
    }

    private func isWholeWord(
        _ range: Range<String.Index>,
        in candidate: String
    ) -> Bool {
        let wordCharacters = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "_")
        )
        let hasWordBefore: Bool
        if range.lowerBound == candidate.startIndex {
            hasWordBefore = false
        } else {
            let previous = candidate.index(before: range.lowerBound)
            hasWordBefore = candidate[previous].unicodeScalars.contains {
                wordCharacters.contains($0)
            }
        }
        let hasWordAfter: Bool
        if range.upperBound == candidate.endIndex {
            hasWordAfter = false
        } else {
            hasWordAfter = candidate[range.upperBound].unicodeScalars.contains {
                wordCharacters.contains($0)
            }
        }
        return !hasWordBefore && !hasWordAfter
    }

    private func matchContext(
        for entry: ClipboardEntry,
        candidate: ClipboardSearchCandidate,
        range: Range<String.Index>
    ) -> String? {
        switch candidate.field {
        case .title:
            return nil
        case .content:
            let position = candidate.text.distance(
                from: candidate.text.startIndex,
                to: range.lowerBound
            )
            if position <= 42 { return nil }
        case .recognizedText, .sourceApplication, .snippetKeyword, .snippetCollection:
            break
        }
        return contextExcerpt(in: candidate.text, around: range)
    }

    private func contextExcerpt(
        in candidate: String,
        around range: Range<String.Index>
    ) -> String {
        let leadingContextCharacters = 14
        let trailingContextCharacters = 58
        let lower = candidate.index(
            range.lowerBound,
            offsetBy: -leadingContextCharacters,
            limitedBy: candidate.startIndex
        ) ?? candidate.startIndex
        let upper = candidate.index(
            range.upperBound,
            offsetBy: trailingContextCharacters,
            limitedBy: candidate.endIndex
        ) ?? candidate.endIndex
        let normalized = String(candidate[lower..<upper])
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let leading = lower == candidate.startIndex ? "" : "…"
        let trailing = upper == candidate.endIndex ? "" : "…"
        return "\(leading)\(normalized)\(trailing)"
    }

    func appendSearchFilter(
        field: ClipboardStructuredQuery.Field,
        value: String
    ) {
        guard let token = ClipboardStructuredQuery.token(field: field, value: value) else {
            return
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        query = trimmed.isEmpty ? token : "\(trimmed) \(token)"
    }

    func removeSearchFilters() {
        query = ClipboardStructuredQuery.parse(query).text
    }
}

private struct ClipboardSearchCandidate {
    let text: String
    let field: ClipboardSearchMatchField
    let fieldPriority: Int
}

private struct ClipboardRankedCandidate {
    let candidate: ClipboardSearchCandidate
    let range: Range<String.Index>
    let rank: ClipboardSearchRelevance
}

private struct ClipboardRankedSearchResult {
    let entry: ClipboardEntry
    let presentation: ClipboardSearchPresentation?
    let rank: ClipboardSearchRelevance?
    let fallbackIndex: Int
}

private struct ClipboardSearchRelevance: Equatable {
    let fieldPriority: Int
    let quality: Int
    let fuzzyScore: Int
    let usageScore: Double
    let copiedDate: Date
    let copyCount: Int
    let position: Int
    let candidateLength: Int

    func isPreferred(over other: Self) -> Bool {
        if fieldPriority != other.fieldPriority { return fieldPriority > other.fieldPriority }
        if quality != other.quality { return quality > other.quality }
        if fuzzyScore != other.fuzzyScore { return fuzzyScore > other.fuzzyScore }
        // Once two entries are equally relevant, favor durable reuse habits,
        // then strict copy recency. Using an item never rewrites copied-at order.
        if usageScore != other.usageScore { return usageScore > other.usageScore }
        if copiedDate != other.copiedDate { return copiedDate > other.copiedDate }
        if copyCount != other.copyCount { return copyCount > other.copyCount }
        if position != other.position { return position < other.position }
        return candidateLength < other.candidateLength
    }
}

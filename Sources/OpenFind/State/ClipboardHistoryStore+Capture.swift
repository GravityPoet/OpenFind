import AppKit
import Foundation

extension ClipboardHistoryStore {
    @discardableResult
    func captureCurrentPasteboard(
        sourceBundleIdentifier: String? = nil,
        sourceApplicationName: String? = nil,
        sourceIdentifiers: Set<String> = []
    ) -> Bool {
        guard !requiresPersistenceMigration else { return false }
        if preferences.capturePaused {
            if preferences.ignoreOnlyNextCapture {
                updatePreferences {
                    $0.capturePaused = false
                    $0.ignoreOnlyNextCapture = false
                }
            }
            return false
        }
        var identifiers = sourceIdentifiers
        if let sourceBundleIdentifier { identifiers.insert(sourceBundleIdentifier) }
        identifiers = Set(identifiers.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        })
        if identifiers.contains(Bundle.main.bundleIdentifier ?? "") { return false }
        let listedApplication = identifiers.contains(where: {
            preferences.ignoredBundleIdentifiers.contains($0)
        })
        if preferences.ignoreAllAppsExceptListed ? !listedApplication : listedApplication {
            return false
        }
        guard let pasteboardItems = pasteboard.pasteboardItems,
              !pasteboardItems.isEmpty else { return false }
        let types = Set(pasteboardItems.flatMap { $0.types.map(\.rawValue) })
        guard !types.contains(Self.internalPasteboardType) else { return false }
        cancelPasteStack()
        guard !types.contains(Self.remoteClipboardType),
              types.isDisjoint(with: Self.ignoredTypes),
              types.isDisjoint(with: preferences.ignoredPasteboardTypes) else { return false }
        guard let content = retainedContent(from: pasteboardItems) else { return false }
        let regexCandidate = String(content.previewText.prefix(100_000))
        if matchesIgnoredPattern(regexCandidate) { return false }
        return ingest(
            representations: content.representations,
            pasteboardItems: content.pasteboardItems,
            previewText: content.previewText,
            kind: content.kind,
            sourceBundleIdentifier: sourceBundleIdentifier,
            sourceApplicationName: sourceApplicationName
        )
    }

    @discardableResult
    func ingest(
        representations: [String: Data],
        pasteboardItems: [[String: Data]]? = nil,
        previewText: String,
        kind: ClipboardEntryKind,
        createdAt: Date = Date(),
        sourceBundleIdentifier: String? = nil,
        sourceApplicationName: String? = nil
    ) -> Bool {
        guard !requiresPersistenceMigration else { return false }
        let retainedItems = pasteboardItems?.isEmpty == false
            ? pasteboardItems! : [representations]
        let totalBytes = retainedItems.flatMap(\.values).reduce(0) { $0 + $1.count }
        guard !retainedItems.isEmpty, retainedItems.contains(where: { !$0.isEmpty }) else {
            return false
        }
        guard totalBytes <= itemLimitBytes else {
            lastErrorMessage = ClipboardHistoryError.contentTooLarge.localizedDescription
            return false
        }
        let retainedEntryID: UUID
        if let duplicateIndex = entries.firstIndex(where: {
            $0.retainedPasteboardItems == retainedItems
        }) {
            var duplicate = entries.remove(at: duplicateIndex)
            duplicate.firstCopiedAt = duplicate.initialCopiedAt
            duplicate.createdAt = createdAt
            duplicate.previewText = String(previewText.prefix(4_096))
            duplicate.kind = kind
            duplicate.representations = representations
            duplicate.pasteboardItems = pasteboardItems
            duplicate.copyCount = duplicate.numberOfCopies + 1
            duplicate.sourceBundleIdentifier = normalizedMetadata(
                sourceBundleIdentifier,
                limit: 512
            ) ?? duplicate.sourceBundleIdentifier
            duplicate.sourceApplicationName = normalizedMetadata(
                sourceApplicationName,
                limit: 256
            ) ?? duplicate.sourceApplicationName
            retainedEntryID = duplicate.id
            entries.insert(duplicate, at: 0)
        } else {
            let entry = ClipboardEntry(
                createdAt: createdAt,
                previewText: String(previewText.prefix(4_096)),
                kind: kind,
                representations: representations,
                pasteboardItems: pasteboardItems,
                firstCopiedAt: createdAt,
                sourceBundleIdentifier: normalizedMetadata(sourceBundleIdentifier, limit: 512),
                sourceApplicationName: normalizedMetadata(sourceApplicationName, limit: 256),
                copyCount: 1
            )
            retainedEntryID = entry.id
            entries.insert(entry, at: 0)
        }
        trimToLimits(referenceDate: createdAt)
        guard entries.contains(where: { $0.id == retainedEntryID }) else {
            lastErrorMessage = ClipboardHistoryError.historyFull.localizedDescription
            return false
        }
        selectedIndex = 0
        clearMultiSelection()
        persist()
        return true
    }
}

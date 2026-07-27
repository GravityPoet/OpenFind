import Foundation

enum ClipboardEntryKind: String, Codable, Sendable {
    case text
    case richText
    case url
    case file
    case image
    case other

    /// Some applications copy a visible URL as plain text without also
    /// declaring `public.url`. Treat only a complete HTTP(S) value as a link;
    /// ordinary prose that merely contains a URL remains text.
    static func resolvingStandaloneURL(
        _ declaredKind: ClipboardEntryKind,
        previewText: String
    ) -> ClipboardEntryKind {
        guard declaredKind == .text || declaredKind == .richText,
              standaloneWebURL(in: previewText) != nil else {
            return declaredKind
        }
        return .url
    }

    static func standaloneWebURL(in text: String) -> URL? {
        let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty,
              !candidate.contains(where: \.isWhitespace),
              let url = URL(string: candidate),
              !url.isFileURL,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else {
            return nil
        }
        return url
    }
}

/// One-tap content-type filter for the history panel, in the spirit of
/// Raycast's clipboard filters. Session-scoped on purpose: a filter that
/// silently persists across panel openings reads as "my history vanished".
enum ClipboardKindFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case text
    case image
    case link
    case file

    var id: Self { self }

    func matches(_ kind: ClipboardEntryKind) -> Bool {
        switch self {
        case .all: true
        case .text: kind == .text || kind == .richText
        case .image: kind == .image
        case .link: kind == .url
        case .file: kind == .file
        }
    }

    var localizedTitle: String {
        switch self {
        case .all: L("Kind Filter All")
        case .text: L("Kind Filter Text")
        case .image: L("Kind Filter Images")
        case .link: L("Kind Filter Links")
        case .file: L("Kind Filter Files")
        }
    }
}

struct ClipboardEntry: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var createdAt: Date
    var firstCopiedAt: Date?
    var previewText: String
    var kind: ClipboardEntryKind
    var representations: [String: Data]
    var pasteboardItems: [[String: Data]]?
    var isPinned: Bool
    var pinKey: String?
    var customTitle: String?
    var sourceBundleIdentifier: String?
    var sourceApplicationName: String?
    var recognizedText: String?
    var imageTextRecognitionRevision: Int?
    var copyCount: Int?
    var snippetCollection: String?
    var snippetKeyword: String?
    var snippetExpansionEnabled: Bool?

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        previewText: String,
        kind: ClipboardEntryKind,
        representations: [String: Data],
        pasteboardItems: [[String: Data]]? = nil,
        isPinned: Bool = false,
        pinKey: String? = nil,
        customTitle: String? = nil,
        firstCopiedAt: Date? = nil,
        sourceBundleIdentifier: String? = nil,
        sourceApplicationName: String? = nil,
        recognizedText: String? = nil,
        imageTextRecognitionRevision: Int? = nil,
        copyCount: Int? = nil,
        snippetCollection: String? = nil,
        snippetKeyword: String? = nil,
        snippetExpansionEnabled: Bool? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.firstCopiedAt = firstCopiedAt
        self.previewText = previewText
        self.kind = kind
        self.representations = representations
        self.pasteboardItems = pasteboardItems
        self.isPinned = isPinned
        self.pinKey = pinKey
        self.customTitle = customTitle
        self.sourceBundleIdentifier = sourceBundleIdentifier
        self.sourceApplicationName = sourceApplicationName
        self.recognizedText = recognizedText
        self.imageTextRecognitionRevision = imageTextRecognitionRevision
        self.copyCount = copyCount
        self.snippetCollection = snippetCollection
        self.snippetKeyword = snippetKeyword
        self.snippetExpansionEnabled = snippetExpansionEnabled
    }

    var initialCopiedAt: Date { firstCopiedAt ?? createdAt }

    var numberOfCopies: Int { max(1, copyCount ?? 1) }

    var expandsFromKeyword: Bool {
        isPinned && snippetExpansionEnabled == true && snippetKeyword?.isEmpty == false
    }

    var retainedPasteboardItems: [[String: Data]] {
        guard let pasteboardItems, !pasteboardItems.isEmpty else {
            return representations.isEmpty ? [] : [representations]
        }
        return pasteboardItems
    }

    var displayTitle: String {
        guard let alias = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !alias.isEmpty else { return previewText }
        return alias
    }
}

enum ClipboardHistoryError: Error, Equatable, LocalizedError {
    case unsupportedContent
    case contentTooLarge
    case persistenceUnavailable
    case persistenceCorrupt
    case persistenceDesynchronized
    case pasteboardWriteFailed
    case entryNotFound
    case historyFull
    case pasteStackMonitorUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupportedContent:
            return L("Clipboard Unsupported Content")
        case .contentTooLarge:
            return L("Clipboard Content Too Large")
        case .persistenceUnavailable:
            return L("Clipboard Persistence Unavailable")
        case .persistenceCorrupt:
            return L("Clipboard Persistence Corrupt")
        case .persistenceDesynchronized:
            return L("Clipboard Persistence Desynchronized")
        case .pasteboardWriteFailed:
            return L("Clipboard Pasteboard Write Failed")
        case .entryNotFound:
            return L("Clipboard Entry Missing")
        case .historyFull:
            return L("Clipboard History Full")
        case .pasteStackMonitorUnavailable:
            return L("Clipboard Paste Stack Monitor Unavailable")
        }
    }
}

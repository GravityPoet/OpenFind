import Foundation

enum ClipboardEntryKind: String, Codable, Sendable {
    case text
    case richText
    case url
    case file
    case image
    case other
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

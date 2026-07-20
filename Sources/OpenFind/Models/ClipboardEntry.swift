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
    var previewText: String
    var kind: ClipboardEntryKind
    var representations: [String: Data]
    var isPinned: Bool

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        previewText: String,
        kind: ClipboardEntryKind,
        representations: [String: Data],
        isPinned: Bool = false
    ) {
        self.id = id
        self.createdAt = createdAt
        self.previewText = previewText
        self.kind = kind
        self.representations = representations
        self.isPinned = isPinned
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
        }
    }
}

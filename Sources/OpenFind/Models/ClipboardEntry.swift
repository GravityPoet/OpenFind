import CryptoKit
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

struct ClipboardPayloadDescriptor: Codable, Equatable, Sendable {
    let byteCount: Int
    let fingerprint: Data
    let itemCount: Int
    let typeNames: [String]
    /// Hash of the normalized plain-text representation, when the first
    /// pasteboard item has one. This lets the Quick Merge event tap identify a
    /// cold entry without decrypting a potentially multi-megabyte payload.
    let plainTextFingerprint: Data?

    var hasPlainText: Bool {
        plainTextFingerprint != nil || !Set(typeNames).isDisjoint(with: [
            "public.utf8-plain-text",
            "public.utf16-external-plain-text",
            "public.text",
        ])
    }

    static func make(for items: [[String: Data]]) -> ClipboardPayloadDescriptor? {
        guard !items.isEmpty, items.contains(where: { !$0.isEmpty }) else { return nil }
        var hasher = SHA256()
        update(UInt64(items.count), in: &hasher)
        var byteCount = 0
        var typeNames = Set<String>()
        var plainTextFingerprint: Data?
        for (itemIndex, item) in items.enumerated() {
            update(UInt64(itemIndex), in: &hasher)
            let sortedTypes = item.keys.sorted()
            update(UInt64(sortedTypes.count), in: &hasher)
            for type in sortedTypes {
                guard let data = item[type] else { continue }
                let typeData = Data(type.utf8)
                update(UInt64(typeData.count), in: &hasher)
                hasher.update(data: typeData)
                update(UInt64(data.count), in: &hasher)
                hasher.update(data: data)
                byteCount += data.count
                typeNames.insert(type)
            }
            if itemIndex == 0 {
                let preferredTypes = [
                    "public.utf8-plain-text",
                    "public.utf16-external-plain-text",
                    "public.text",
                ]
                for type in preferredTypes {
                    guard let data = item[type],
                          let text = textValue(data: data, type: type) else { continue }
                    plainTextFingerprint = Data(SHA256.hash(data: Data(text.utf8)))
                    break
                }
            }
        }
        return ClipboardPayloadDescriptor(
            byteCount: byteCount,
            fingerprint: Data(hasher.finalize()),
            itemCount: items.count,
            typeNames: typeNames.sorted(),
            plainTextFingerprint: plainTextFingerprint
        )
    }

    private static func textValue(data: Data, type: String) -> String? {
        switch type {
        case "public.utf8-plain-text",
             "public.text":
            return String(data: data, encoding: .utf8)
        case "public.utf16-external-plain-text":
            return String(data: data, encoding: .utf16)
        default:
            return nil
        }
    }

    private static func update(_ value: UInt64, in hasher: inout SHA256) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { buffer in
            hasher.update(data: Data(buffer))
        }
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
    var lastUsedAt: Date?
    var useCount: Int?
    var usageScore: Double?
    var frequentOverride: Bool?
    var frequentOverrideAt: Date?
    var snippetCollection: String?
    var snippetKeyword: String?
    var snippetExpansionEnabled: Bool?
    var payloadDescriptor: ClipboardPayloadDescriptor?

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
        lastUsedAt: Date? = nil,
        useCount: Int? = nil,
        usageScore: Double? = nil,
        frequentOverride: Bool? = nil,
        frequentOverrideAt: Date? = nil,
        snippetCollection: String? = nil,
        snippetKeyword: String? = nil,
        snippetExpansionEnabled: Bool? = nil,
        payloadDescriptor: ClipboardPayloadDescriptor? = nil
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
        self.lastUsedAt = lastUsedAt
        self.useCount = useCount
        self.usageScore = usageScore
        self.frequentOverride = frequentOverride
        self.frequentOverrideAt = frequentOverrideAt
        self.snippetCollection = snippetCollection
        self.snippetKeyword = snippetKeyword
        self.snippetExpansionEnabled = snippetExpansionEnabled
        self.payloadDescriptor = payloadDescriptor ?? ClipboardPayloadDescriptor.make(
            for: self.retainedPasteboardItems
        )
    }

    var initialCopiedAt: Date { firstCopiedAt ?? createdAt }

    var numberOfCopies: Int { max(1, copyCount ?? 1) }

    var numberOfUses: Int { max(0, useCount ?? 0) }

    var hasCustomTitle: Bool {
        customTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    func decayedUsageScore(at referenceDate: Date) -> Double {
        guard numberOfUses > 0, let lastUsedAt else { return 0 }
        let baseScore = max(0, usageScore ?? Double(numberOfUses))
        let elapsed = max(0, referenceDate.timeIntervalSince(lastUsedAt))
        let halfLives = elapsed / (14 * 24 * 60 * 60)
        return baseScore * pow(0.5, halfLives)
    }

    var expandsFromKeyword: Bool {
        isPinned && snippetExpansionEnabled == true && snippetKeyword?.isEmpty == false
    }

    var retainedPasteboardItems: [[String: Data]] {
        guard let pasteboardItems, !pasteboardItems.isEmpty else {
            return representations.isEmpty ? [] : [representations]
        }
        return pasteboardItems
    }

    var resolvedPayloadDescriptor: ClipboardPayloadDescriptor? {
        ClipboardPayloadDescriptor.make(for: retainedPasteboardItems) ?? payloadDescriptor
    }

    var hasResidentPayload: Bool {
        retainedPasteboardItems.contains { !$0.isEmpty }
    }

    func synchronizingPayloadDescriptor() -> ClipboardEntry {
        guard hasResidentPayload else { return self }
        var entry = self
        entry.payloadDescriptor = ClipboardPayloadDescriptor.make(
            for: retainedPasteboardItems
        )
        return entry
    }

    func strippingPayload() -> ClipboardEntry {
        var entry = synchronizingPayloadDescriptor()
        entry.representations = [:]
        entry.pasteboardItems = nil
        return entry
    }

    func restoringPayload(from stored: ClipboardEntry) throws -> ClipboardEntry {
        guard id == stored.id,
              let expected = resolvedPayloadDescriptor,
              stored.synchronizingPayloadDescriptor().resolvedPayloadDescriptor == expected else {
            throw ClipboardHistoryError.persistenceDesynchronized
        }
        var entry = self
        entry.representations = stored.representations
        entry.pasteboardItems = stored.pasteboardItems
        entry.payloadDescriptor = expected
        return entry
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

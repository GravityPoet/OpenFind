import AppKit
import Foundation

extension ClipboardHistoryStore {
    func retainedContent(
        from items: [NSPasteboardItem]
    ) -> (
        representations: [String: Data],
        pasteboardItems: [[String: Data]]?,
        previewText: String,
        kind: ClipboardEntryKind
    )? {
        var retainedItems: [[String: Data]] = []
        var totalBytes = 0
        for item in items {
            var representations: [String: Data] = [:]
            for type in item.types where shouldRetain(type.rawValue) {
                guard let data = item.data(forType: type), !data.isEmpty else { continue }
                totalBytes += data.count
                guard totalBytes <= itemLimitBytes else {
                    lastErrorMessage = ClipboardHistoryError.contentTooLarge.localizedDescription
                    return nil
                }
                representations[type.rawValue] = data
            }
            if !representations.isEmpty { retainedItems.append(representations) }
        }
        let normalizedItems = normalizedPasteboardItems(retainedItems)
        guard let primary = normalizedItems.first,
              let presentation = contentPresentation(for: normalizedItems) else {
            lastErrorMessage = ClipboardHistoryError.unsupportedContent.localizedDescription
            return nil
        }
        return (
            primary,
            normalizedItems.count > 1 ? normalizedItems : nil,
            presentation.previewText,
            presentation.kind
        )
    }

    func matchesIgnoredPattern(_ candidate: String) -> Bool {
        preferences.ignoredTextPatterns.contains { pattern in
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return false }
            let range = NSRange(candidate.startIndex..., in: candidate)
            return expression.firstMatch(in: candidate, range: range) != nil
        }
    }

    func storageCategory(for type: String) -> ClipboardStorageCategory? {
        if type == "public.file-url" { return .files }
        let imageTypes = ["public.png", "public.tiff", "public.jpeg", "public.heic"]
        if imageTypes.contains(type) { return .images }
        let textTypes = [
            NSPasteboard.PasteboardType.string.rawValue,
            "public.utf8-plain-text", "public.utf16-external-plain-text",
            "public.rtf", "public.html", "public.url",
        ]
        return textTypes.contains(type) ? .text : nil
    }

    func normalizedMetadata(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else { return nil }
        return String(normalized.prefix(limit))
    }

    private func contentPresentation(
        for items: [[String: Data]]
    ) -> (previewText: String, kind: ClipboardEntryKind)? {
        let allRepresentations = items.flatMap { $0.map { ($0.key, $0.value) } }
        let keys = Set(allRepresentations.map(\.0))
        let files = allRepresentations.compactMap { type, data -> URL? in
            guard type == "public.file-url" else { return nil }
            return URL(dataRepresentation: data, relativeTo: nil)
        }
        if !files.isEmpty {
            return (files.map(\.lastPathComponent).joined(separator: "\n"), .file)
        }
        if let pair = allRepresentations.first(where: { $0.0 == "public.url" }),
           let url = URL(dataRepresentation: pair.1, relativeTo: nil) {
            return (url.absoluteString, .url)
        }
        if let text = firstPlainText(in: allRepresentations) {
            let kind: ClipboardEntryKind = keys.contains("public.rtf") || keys.contains("public.html")
                ? .richText : .text
            return (text, kind)
        }
        let imageTypes = ["public.png", "public.tiff", "public.jpeg", "public.heic"]
        if !keys.isDisjoint(with: imageTypes) { return ("Image", .image) }
        return allRepresentations.isEmpty ? nil : ("Clipboard item", .other)
    }

    private func firstPlainText(in representations: [(String, Data)]) -> String? {
        let preferred = [
            NSPasteboard.PasteboardType.string.rawValue,
            "public.utf8-plain-text",
            "public.utf16-external-plain-text",
        ]
        for type in preferred {
            guard let data = representations.first(where: { $0.0 == type })?.1 else { continue }
            let encoding: String.Encoding = type == "public.utf16-external-plain-text"
                ? .utf16 : .utf8
            if let text = String(data: data, encoding: encoding) { return text }
        }
        return nil
    }

    private func shouldRetain(_ type: String) -> Bool {
        guard Self.supportedTypes.contains(type),
              let category = storageCategory(for: type) else { return false }
        return preferences.enabledStorageCategories.contains(category)
    }

    private func normalizedPasteboardItems(
        _ items: [[String: Data]]
    ) -> [[String: Data]] {
        let fileURLs = items.compactMap { $0["public.file-url"] }
        if !fileURLs.isEmpty {
            return fileURLs.map { ["public.file-url": $0] }
        }
        var merged: [String: Data] = [:]
        for item in items {
            for (type, data) in item where merged[type] == nil {
                merged[type] = data
            }
        }
        return merged.isEmpty ? [] : [merged]
    }
}

import AppKit
import Foundation

extension ClipboardHistoryStore {
    var pinnedEntries: [ClipboardEntry] {
        filteredEntries.filter(\.isPinned)
    }

    func availablePinKeys(excluding entry: ClipboardEntry? = nil) -> [String] {
        ClipboardPinKey.available(in: entries, excluding: entry?.id)
    }

    @discardableResult
    func setPinKey(_ key: String, for entry: ClipboardEntry) -> Bool {
        guard let normalized = ClipboardPinKey.normalize(key),
              let index = entries.firstIndex(where: { $0.id == entry.id && $0.isPinned }),
              !entries.contains(where: {
                  $0.id != entry.id && ClipboardPinKey.normalize($0.pinKey) == normalized
              }) else { return false }
        entries[index].pinKey = normalized
        persist()
        return true
    }

    func setCustomTitle(_ title: String, for entry: ClipboardEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id && $0.isPinned }) else {
            return
        }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            entries[index].customTitle = nil
        } else if let normalized = normalizedMetadata(trimmed, limit: 4_096) {
            entries[index].customTitle = normalized
        } else {
            return
        }
        persist()
    }

    @discardableResult
    func setPlainText(_ text: String, for entry: ClipboardEntry) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == entry.id && $0.isPinned }),
              [.text, .richText, .url].contains(entries[index].kind),
              let data = String(text.prefix(100_000)).data(using: .utf8),
              data.count <= itemLimitBytes else { return false }
        let representations = [NSPasteboard.PasteboardType.string.rawValue: data]
        entries[index].representations = representations
        entries[index].pasteboardItems = nil
        entries[index].previewText = String(text.prefix(4_096))
        entries[index].kind = .text
        persist()
        return true
    }

    @discardableResult
    func normalizePinnedKeys() -> Bool {
        var changed = false
        var assigned = Set<String>()
        for index in entries.indices {
            guard entries[index].isPinned else {
                if entries[index].pinKey != nil {
                    entries[index].pinKey = nil
                    changed = true
                }
                continue
            }
            if let key = ClipboardPinKey.normalize(entries[index].pinKey),
               assigned.insert(key).inserted {
                if entries[index].pinKey != key {
                    entries[index].pinKey = key
                    changed = true
                }
                continue
            }
            let replacement = ClipboardPinKey.supported.first { !assigned.contains($0) }
            if entries[index].pinKey != replacement {
                entries[index].pinKey = replacement
                changed = true
            }
            if let replacement { assigned.insert(replacement) }
        }
        return changed
    }
}

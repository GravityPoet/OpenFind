import Foundation

enum ClipboardPinKey {
    static let supported = [
        "b", "c", "d", "e", "g", "h", "i", "j", "k", "l",
        "m", "n", "o", "r", "s", "t", "u", "x", "y",
    ]

    static func normalize(_ value: String?) -> String? {
        guard let value else { return nil }
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return supported.contains(key) ? key : nil
    }

    static func available(
        in entries: [ClipboardEntry],
        excluding excludedID: UUID? = nil
    ) -> [String] {
        let assigned = Set(entries.compactMap { entry -> String? in
            guard entry.id != excludedID else { return nil }
            return normalize(entry.pinKey)
        })
        return supported.filter { !assigned.contains($0) }
    }
}

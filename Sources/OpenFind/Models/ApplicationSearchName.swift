import Foundation

/// Normalized once during discovery, never transliterated on a keystroke.
struct ApplicationSearchName: Hashable, Sendable {
    let normalized: String
    let initials: String
    let words: [String]
    let pinyin: String
    let pinyinInitials: String

    init(_ name: String) {
        normalized = Self.normalize(name)
        var components: [String] = []
        var word = ""
        let characters = Array(name)
        for (index, character) in characters.enumerated() {
            guard character.isLetter || character.isNumber else {
                if !word.isEmpty { components.append(word); word = "" }
                continue
            }
            if character.isUppercase, index > 0,
               characters[index - 1].isLowercase
                || (characters[index - 1].isUppercase && index + 1 < characters.count
                    && characters[index + 1].isLowercase) {
                if !word.isEmpty { components.append(word); word = "" }
            }
            word.append(character)
        }
        if !word.isEmpty { components.append(word) }
        words = components.map(Self.normalize)
        initials = words.compactMap(\.first).map(String.init).joined()
        if name.unicodeScalars.contains(where: { (0x3400...0x9FFF).contains($0.value) }) {
            let latin = Self.normalize(name.applyingTransform(.toLatin, reverse: false) ?? name)
            let syllables = latin.split(whereSeparator: \.isWhitespace)
            pinyin = syllables.joined()
            pinyinInitials = syllables.compactMap(\.first).map(String.init).joined()
        } else {
            pinyin = ""
            pinyinInitials = ""
        }
    }

    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                     locale: Locale(identifier: "en_US_POSIX"))
            .lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

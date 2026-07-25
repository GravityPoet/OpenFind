import SwiftUI

enum ClipboardHighlightedText {
    static func title(
        for entry: ClipboardEntry,
        query: String,
        preferences: ClipboardPreferences
    ) -> AttributedString {
        let title = visibleTitle(
            entry.displayTitle,
            showSpecialSymbols: preferences.showSpecialSymbols
        )
        return text(
            title,
            query: query,
            preferences: preferences,
            pointSize: ClipboardTypography.rowPointSize
        )
    }

    static func text(
        _ text: String,
        query: String,
        preferences: ClipboardPreferences,
        pointSize: CGFloat
    ) -> AttributedString {
        var attributed = AttributedString(text)
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty,
              let match = ClipboardSearchEngine.match(
                query: normalizedQuery,
                in: text,
                mode: preferences.searchMode
              ) else { return attributed }

        for range in match.ranges {
            guard let lower = AttributedString.Index(range.lowerBound, within: attributed),
                  let upper = AttributedString.Index(range.upperBound, within: attributed) else {
                continue
            }
            let attributedRange = lower..<upper
            switch preferences.highlightStyle {
            case .bold:
                attributed[attributedRange].font = .system(
                    size: pointSize,
                    weight: .bold
                )
            case .color:
                attributed[attributedRange].backgroundColor = .yellow.opacity(0.82)
                attributed[attributedRange].foregroundColor = .black
            case .italic:
                attributed[attributedRange].font = .system(
                    size: pointSize,
                    weight: .medium
                ).italic()
            case .underline:
                attributed[attributedRange].underlineStyle = .single
            }
        }
        return attributed
    }

    static func visibleTitle(_ text: String, showSpecialSymbols: Bool) -> String {
        guard showSpecialSymbols else {
            return text
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
        }
        var title = text
        if let range = title.range(of: "^ +", options: .regularExpression) {
            title.replaceSubrange(range, with: String(repeating: "·", count: title[range].count))
        }
        if let range = title.range(of: " +$", options: .regularExpression) {
            title.replaceSubrange(range, with: String(repeating: "·", count: title[range].count))
        }
        return title
            .replacingOccurrences(of: "\t", with: "⇥")
            .replacingOccurrences(of: "\n", with: "⏎")
    }
}

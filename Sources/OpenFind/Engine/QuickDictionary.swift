import CoreServices
import Foundation

enum QuickDictionary {
    static func definition(for rawWord: String) -> String? {
        let word = rawWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty, word.count <= 120 else { return nil }
        let range = CFRangeMake(0, word.utf16.count)
        guard let value = DCSCopyTextDefinition(nil, word as CFString, range) else { return nil }
        return value.takeRetainedValue() as String
    }
}

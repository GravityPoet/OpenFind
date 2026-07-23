import Foundation

struct ClipboardContentActionDescriptor: Identifiable, Equatable, Sendable {
    let id: String
    let titleKey: String
    let systemImage: String

    var localizedTitle: String { LD(titleKey) }
}

enum ClipboardContentActionError: Error, Equatable, LocalizedError, Sendable {
    case unavailable
    case invalidInput

    var errorDescription: String? {
        switch self {
        case .unavailable: L("Clipboard Content Action Unavailable")
        case .invalidInput: L("Clipboard Content Action Invalid Input")
        }
    }
}

protocol ClipboardContentActionProviding: Sendable {
    func actions(for text: String) -> [ClipboardContentActionDescriptor]
    func transform(actionID: String, text: String) throws -> String
}

struct ClipboardContentActionRegistry: Sendable {
    static let standard = ClipboardContentActionRegistry(providers: [
        StandardClipboardTextActions(),
    ])

    let providers: [any ClipboardContentActionProviding]

    func actions(for text: String) -> [ClipboardContentActionDescriptor] {
        providers.flatMap { $0.actions(for: text) }
    }

    func transform(actionID: String, text: String) throws -> String {
        for provider in providers where provider.actions(for: text).contains(where: {
            $0.id == actionID
        }) {
            return try provider.transform(actionID: actionID, text: text)
        }
        throw ClipboardContentActionError.unavailable
    }
}

struct StandardClipboardTextActions: ClipboardContentActionProviding {
    private enum ID {
        static let trim = "text.trim"
        static let uppercase = "text.uppercase"
        static let lowercase = "text.lowercase"
        static let quote = "text.quote"
        static let jsonPretty = "json.pretty"
        static let jsonMinify = "json.minify"
        static let urlEncode = "url.encode"
        static let urlDecode = "url.decode"
        static let base64Encode = "base64.encode"
        static let base64Decode = "base64.decode"
    }

    func actions(for text: String) -> [ClipboardContentActionDescriptor] {
        var actions: [ClipboardContentActionDescriptor] = [
            .init(id: ID.trim, titleKey: "Trim Whitespace and Copy", systemImage: "text.alignleft"),
            .init(id: ID.uppercase, titleKey: "Uppercase and Copy", systemImage: "textformat.abc.dottedunderline"),
            .init(id: ID.lowercase, titleKey: "Lowercase and Copy", systemImage: "textformat.abc"),
            .init(id: ID.quote, titleKey: "Quote Lines and Copy", systemImage: "quote.bubble"),
            .init(id: ID.urlEncode, titleKey: "URL Encode and Copy", systemImage: "link"),
            .init(id: ID.base64Encode, titleKey: "Base64 Encode and Copy", systemImage: "chevron.left.forwardslash.chevron.right"),
        ]
        if Self.jsonObject(from: text) != nil {
            actions.append(.init(
                id: ID.jsonPretty,
                titleKey: "Format JSON and Copy",
                systemImage: "curlybraces"
            ))
            actions.append(.init(
                id: ID.jsonMinify,
                titleKey: "Minify JSON and Copy",
                systemImage: "arrow.down.right.and.arrow.up.left"
            ))
        }
        if text.removingPercentEncoding != nil,
           text.removingPercentEncoding != text {
            actions.append(.init(
                id: ID.urlDecode,
                titleKey: "URL Decode and Copy",
                systemImage: "link.badge.plus"
            ))
        }
        if let data = Data(base64Encoded: text), String(data: data, encoding: .utf8) != nil {
            actions.append(.init(
                id: ID.base64Decode,
                titleKey: "Base64 Decode and Copy",
                systemImage: "text.page.badge.magnifyingglass"
            ))
        }
        return actions
    }

    func transform(actionID: String, text: String) throws -> String {
        switch actionID {
        case ID.trim:
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        case ID.uppercase:
            return text.localizedUppercase
        case ID.lowercase:
            return text.localizedLowercase
        case ID.quote:
            return text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { "> \($0)" }
                .joined(separator: "\n")
        case ID.jsonPretty:
            return try json(text, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        case ID.jsonMinify:
            return try json(text, options: [.sortedKeys, .withoutEscapingSlashes])
        case ID.urlEncode:
            guard let encoded = text.addingPercentEncoding(
                withAllowedCharacters: .urlQueryAllowed
            ) else { throw ClipboardContentActionError.invalidInput }
            return encoded
        case ID.urlDecode:
            guard let decoded = text.removingPercentEncoding else {
                throw ClipboardContentActionError.invalidInput
            }
            return decoded
        case ID.base64Encode:
            return Data(text.utf8).base64EncodedString()
        case ID.base64Decode:
            guard let data = Data(base64Encoded: text),
                  let decoded = String(data: data, encoding: .utf8) else {
                throw ClipboardContentActionError.invalidInput
            }
            return decoded
        default:
            throw ClipboardContentActionError.unavailable
        }
    }

    private func json(
        _ text: String,
        options: JSONSerialization.WritingOptions
    ) throws -> String {
        guard let object = Self.jsonObject(from: text),
              JSONSerialization.isValidJSONObject(object) else {
            throw ClipboardContentActionError.invalidInput
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: options)
        guard let result = String(data: data, encoding: .utf8) else {
            throw ClipboardContentActionError.invalidInput
        }
        return result
    }

    private static func jsonObject(from text: String) -> Any? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
}

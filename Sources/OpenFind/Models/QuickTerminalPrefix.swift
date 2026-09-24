import Foundation

enum QuickTerminalPrefix {
    static let persistenceKey = "OpenFind.terminalCommandPrefixV1"
    static let defaultValue = "g"
    static let choices = Array("abcdefghijklmnopqrstuvwxyz").map(String.init)

    static func normalized(_ value: String) -> String? {
        let bytes = Array(value.utf8)
        guard bytes.count == 1, (65...90).contains(bytes[0]) || (97...122).contains(bytes[0]) else {
            return nil
        }
        return value.lowercased()
    }

    static func load(from defaults: UserDefaults = .standard) -> String {
        normalized(defaults.string(forKey: persistenceKey) ?? "") ?? defaultValue
    }
}

import Foundation

enum TerminalCommandTarget: String, CaseIterable, Sendable {
    case systemDefault
    case terminal
    case ghostty

    static let persistenceKey = "OpenFind.terminalCommandTargetV1"
    static let defaultValue: Self = .systemDefault

    var titleKey: String {
        switch self {
        case .systemDefault: return "System Default Terminal"
        case .terminal: return "Terminal"
        case .ghostty: return "Ghostty"
        }
    }

    var bundleIdentifier: String? {
        switch self {
        case .systemDefault: return nil
        case .terminal: return "com.apple.Terminal"
        case .ghostty: return "com.mitchellh.ghostty"
        }
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        .init(rawValue: defaults.string(forKey: persistenceKey) ?? "") ?? defaultValue
    }
}

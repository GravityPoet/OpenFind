import Foundation

enum TerminalCommandTarget: String, CaseIterable, Sendable {
    case systemDefault
    case terminal
    case ghostty
    case iterm2

    static let persistenceKey = "OpenFind.terminalCommandTargetV1"
    static let defaultValue: Self = .terminal
    static let directTargets: [Self] = [.terminal, .ghostty, .iterm2]

    var titleKey: String {
        switch self {
        case .systemDefault: return "System Default Terminal"
        case .terminal: return "Terminal"
        case .ghostty: return "Ghostty"
        case .iterm2: return "iTerm2"
        }
    }

    var bundleIdentifier: String? {
        switch self {
        case .systemDefault: return nil
        case .terminal: return "com.apple.Terminal"
        case .ghostty: return "com.mitchellh.ghostty"
        case .iterm2: return "com.googlecode.iterm2"
        }
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        if let stored = defaults.string(forKey: persistenceKey), let target = Self(rawValue: stored) {
            return target
        }
        // An existing customer who never chose a terminal used the old default.
        if defaults.object(forKey: persistenceKey) == nil,
           defaults.bool(forKey: FirstRunGuideStore.completionKey) { return .systemDefault }
        return defaultValue
    }

    /// Run before the welcome guide can change the first-launch marker.
    static func initializeSelection(in defaults: UserDefaults) {
        if defaults.object(forKey: persistenceKey) == nil {
            defaults.set(load(from: defaults).rawValue, forKey: persistenceKey)
        }
    }
}

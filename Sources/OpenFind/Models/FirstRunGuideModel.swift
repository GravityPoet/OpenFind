import Foundation

struct FirstRunCapability: Identifiable, Equatable, Sendable {
    enum ID: String, CaseIterable, Sendable {
        case search
        case clipboard
        case keepAwake
        case driveAlive
        case keyboardCleaning
    }

    let id: ID
    let systemImage: String
    let title: String
    let detail: String
    let shortcut: String
}

struct FirstRunGuideCopy: Equatable, Sendable {
    let title: String
    let subtitle: String
    let dismiss: String
    let reopenHelp: String
    let openSettings: String
    let startSearching: String
    let shortcutFormat: String

    static var localized: Self {
        Self(
            title: L("Welcome to OpenFind"),
            subtitle: L("Five Mac tools, one quiet menu bar app. Start with search, then use each tool when you need it."),
            dismiss: L("Not Now"),
            reopenHelp: L("Reopen this guide from the OpenFind menu at any time."),
            openSettings: L("Open Settings"),
            startSearching: L("Start Searching"),
            shortcutFormat: L("Shortcut Format")
        )
    }
}

enum FirstRunGuideStore {
    static let completionKey = "OpenFind.firstRunGuideCompletedV1"

    static func shouldPresent(defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: completionKey)
    }

    static func markCompleted(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: completionKey)
    }
}

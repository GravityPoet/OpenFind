import Carbon
import Foundation

enum ClipboardStorageCategory: String, CaseIterable, Codable, Hashable, Sendable {
    case text
    case images
    case files
}

enum ClipboardRetentionPeriod: String, CaseIterable, Codable, Identifiable, Sendable {
    case days3
    case days7
    case days15
    case days30
    case forever

    var id: Self { self }

    var duration: TimeInterval? {
        switch self {
        case .days3: 3 * 24 * 60 * 60
        case .days7: 7 * 24 * 60 * 60
        case .days15: 15 * 24 * 60 * 60
        case .days30: 30 * 24 * 60 * 60
        case .forever: nil
        }
    }

    func cutoff(referenceDate: Date) -> Date? {
        duration.map { referenceDate.addingTimeInterval(-$0) }
    }
}

enum ClipboardSearchMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case exact
    case fuzzy
    case regularExpression
    case mixed

    var id: Self { self }
}

enum ClipboardSortMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case lastCopied
    case firstCopied

    var id: Self { self }
}

enum ClipboardPinsPosition: String, CaseIterable, Codable, Identifiable, Sendable {
    case top
    case bottom

    var id: Self { self }
}

enum ClipboardPopupPosition: String, CaseIterable, Codable, Identifiable, Sendable {
    case cursor
    case center
    case lastPosition

    var id: Self { self }
}

enum ClipboardHighlightStyle: String, CaseIterable, Codable, Identifiable, Sendable {
    case bold
    case color
    case italic
    case underline

    var id: Self { self }
}

enum ClipboardQuickMergeSeparator: String, CaseIterable, Codable, Identifiable, Sendable {
    case newline
    case space
    case none
    case custom

    var id: Self { self }
}

struct ClipboardPreferences: Codable, Equatable, Sendable {
    var retentionPeriod = ClipboardRetentionPeriod.days30
    var itemLimitBytes = 8 * 1_024 * 1_024
    var enabledStorageCategories = Set(ClipboardStorageCategory.allCases)
    var ignoredBundleIdentifiers: Set<String> = []
    var allowedBundleIdentifiers: Set<String> = []
    var captureOnlyFromAllowedApplications = false
    var ignoredPasteboardTypes: Set<String> = Self.defaultIgnoredPasteboardTypes
    var ignoredTextPatterns: [String] = []
    var capturePaused = false
    var ignoreOnlyNextCapture = false
    var clipboardCheckInterval = 0.5
    var pasteWithoutFormatting = false
    var clearHistoryOnQuit = false
    var clearSystemClipboardOnQuit = false
    var searchMode = ClipboardSearchMode.exact
    var sortMode = ClipboardSortMode.lastCopied
    var pinsPosition = ClipboardPinsPosition.top
    var popupPosition = ClipboardPopupPosition.center
    var popupScreen = 0
    var openPreviewAutomatically = true
    var previewDelayMilliseconds = 1_500
    var previewWidth = 400.0
    var imageRowHeight = 40
    var highlightStyle = ClipboardHighlightStyle.bold
    var showFooter = true
    var showApplicationIcons = true
    var showSpecialSymbols = true
    var showHexColorSwatch = true
    var showRecentCopyInMenuBar = false
    var imageTextRecognitionEnabled = true
    var snippetExpansionEnabled = false
    var quickMergeEnabled = false
    var quickMergeSeparator = ClipboardQuickMergeSeparator.newline
    var quickMergeCustomSeparator = " · "
    var pinShortcut = Self.defaultPinShortcut
    var deleteShortcut = Self.defaultDeleteShortcut
    var previewShortcut = Self.defaultPreviewShortcut

    static let defaultPinShortcut = GlobalShortcut(
        keyCode: UInt32(kVK_ANSI_P),
        modifiers: UInt32(optionKey),
        keyLabel: "P"
    )
    static let defaultDeleteShortcut = GlobalShortcut(
        keyCode: UInt32(kVK_Delete),
        modifiers: UInt32(optionKey),
        keyLabel: "⌫"
    )
    static let defaultPreviewShortcut = GlobalShortcut(
        keyCode: UInt32(kVK_Space),
        modifiers: UInt32(controlKey),
        keyLabel: "Space"
    )

    static let defaultIgnoredPasteboardTypes: Set<String> = [
        "Pasteboard generator type",
        "com.agilebits.onepassword",
        "com.agilebits.onepassword.password",
        "com.typeit4me.clipping",
        "de.petermaurer.TransientPasteboardType",
        "net.antelle.keeweb",
    ]

    static let defaultIgnoredBundleIdentifiersV1: Set<String> = [
        "com.1password.1password",
        "com.apple.Passwords",
        "com.bitwarden.desktop",
    ]

    static let defaultIgnoredApplicationNames: [String: String] = [
        "com.1password.1password": "1Password",
        "com.agilebits.onepassword7": "1Password 7",
        "com.app77.pwsafemac": "pwSafe",
        "com.apple.Passwords": "Passwords",
        "com.apple.keychainaccess": "Keychain Access",
        "com.bitwarden.desktop": "Bitwarden",
        "com.callpod.keepermac.lite": "Keeper",
        "com.dashlane.dashlanephonefinal": "Dashlane",
        "com.keepassium.intune": "KeePassium for Intune",
        "com.keepassium.ios": "KeePassium",
        "com.keepassium.ios.pro": "KeePassium Pro",
        "com.lastpass.lastpassforsafari": "LastPass for Safari",
        "com.markmcguill.strongbox": "Strongbox",
        "com.markmcguill.strongbox.graphene": "Strongbox Zero",
        "com.markmcguill.strongbox.mac": "Strongbox",
        "com.markmcguill.strongbox.mac.pro": "Strongbox Pro",
        "com.markmcguill.strongbox.pro": "Strongbox Pro",
        "com.mseven.msecuremac": "mSecure",
        "com.nordpass.safari.app.password.manager": "NordPass",
        "com.outercorner.Secrets": "Secrets",
        "com.pcloud.pcloudPass": "pCloud Pass",
        "com.safeincloud.Safe-In-Cloud.OSX": "SafeInCloud",
        "com.sibersystems.RoboFormMac": "RoboForm",
        "in.sinew.Enpass-Desktop": "Enpass",
        "me.proton.pass.catalyst": "Proton Pass",
        "net.zetetic.Strip.mac": "Codebook",
        "org.keepassxc.keepassxc": "KeePassXC",
    ]

    static let defaultIgnoredBundleIdentifiers = Set(defaultIgnoredApplicationNames.keys)
    static let defaultIgnoredBundleIdentifiersV2 =
        defaultIgnoredBundleIdentifiers.subtracting(defaultIgnoredBundleIdentifiersV1)

    func normalized() -> Self {
        var value = self
        value.itemLimitBytes = min(16 * 1_024 * 1_024, max(1_024, itemLimitBytes))
        value.ignoredBundleIdentifiers = Self.normalizedStrings(
            ignoredBundleIdentifiers,
            countLimit: 128,
            lengthLimit: 512
        )
        value.allowedBundleIdentifiers = Self.normalizedStrings(
            allowedBundleIdentifiers,
            countLimit: 128,
            lengthLimit: 512
        )
        value.ignoredPasteboardTypes = Self.normalizedStrings(
            ignoredPasteboardTypes,
            countLimit: 128,
            lengthLimit: 512
        )
        value.ignoredTextPatterns = ignoredTextPatterns.compactMap { pattern in
            let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  trimmed.count <= 512,
                  (try? NSRegularExpression(pattern: trimmed)) != nil else { return nil }
            return trimmed
        }.uniqued().prefix(128).map { $0 }
        value.clipboardCheckInterval = min(5, max(0.1, clipboardCheckInterval))
        value.quickMergeCustomSeparator = String(
            quickMergeCustomSeparator
                .filter { !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }
                .prefix(16)
        )
        value.popupScreen = max(0, popupScreen)
        value.previewDelayMilliseconds = min(100_000, max(200, previewDelayMilliseconds))
        value.previewWidth = min(800, max(260, previewWidth))
        value.imageRowHeight = min(200, max(16, imageRowHeight))
        if !value.pinShortcut.isValid { value.pinShortcut = Self.defaultPinShortcut }
        if !value.deleteShortcut.isValid { value.deleteShortcut = Self.defaultDeleteShortcut }
        if !value.previewShortcut.isValid { value.previewShortcut = Self.defaultPreviewShortcut }
        if value.ignoreOnlyNextCapture { value.capturePaused = true }
        return value
    }

    private static func normalizedStrings(
        _ values: Set<String>,
        countLimit: Int,
        lengthLimit: Int
    ) -> Set<String> {
        Set(values.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  trimmed.count <= lengthLimit,
                  trimmed.unicodeScalars.allSatisfy({
                      !CharacterSet.controlCharacters.contains($0)
                  }) else { return nil }
            return trimmed
        }.sorted().prefix(countLimit))
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

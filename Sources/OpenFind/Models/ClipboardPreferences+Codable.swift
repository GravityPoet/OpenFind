import Foundation

extension ClipboardPreferences {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case retentionPeriod, historyLimit, itemLimitBytes, enabledStorageCategories
        case ignoredBundleIdentifiers, allowedBundleIdentifiers
        case captureOnlyFromAllowedApplications, ignoreAllAppsExceptListed
        case ignoredPasteboardTypes, ignoredTextPatterns
        case capturePaused, ignoreOnlyNextCapture, clipboardCheckInterval
        case pasteWithoutFormatting, clearHistoryOnQuit, clearSystemClipboardOnQuit
        case searchMode, sortMode, pinsPosition, popupPosition, popupScreen
        case openPreviewAutomatically, previewDelayMilliseconds, previewWidth
        case imageRowHeight, highlightStyle, showFooter
        case showApplicationIcons, showSpecialSymbols, showHexColorSwatch
        case showRecentCopyInMenuBar, pinShortcut, deleteShortcut, previewShortcut
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var value = Self()
        if let retentionPeriod = try container.decodeIfPresent(
            ClipboardRetentionPeriod.self,
            forKey: .retentionPeriod
        ) {
            value.retentionPeriod = retentionPeriod
        } else if container.contains(.historyLimit) {
            // The previous model used a numeric count. Preserve every existing
            // clip during migration instead of guessing an expiry date.
            value.retentionPeriod = .forever
        }
        value.itemLimitBytes = try container.decodeIfPresent(Int.self, forKey: .itemLimitBytes)
            ?? value.itemLimitBytes
        value.enabledStorageCategories = try container.decodeIfPresent(
            Set<ClipboardStorageCategory>.self,
            forKey: .enabledStorageCategories
        ) ?? value.enabledStorageCategories
        value.ignoredBundleIdentifiers = try container.decodeIfPresent(
            Set<String>.self,
            forKey: .ignoredBundleIdentifiers
        ) ?? value.ignoredBundleIdentifiers
        value.allowedBundleIdentifiers = try container.decodeIfPresent(
            Set<String>.self,
            forKey: .allowedBundleIdentifiers
        ) ?? value.allowedBundleIdentifiers
        value.captureOnlyFromAllowedApplications = try container.decodeIfPresent(
            Bool.self,
            forKey: .captureOnlyFromAllowedApplications
        ) ?? container.decodeIfPresent(
            Bool.self,
            forKey: .ignoreAllAppsExceptListed
        ) ?? value.captureOnlyFromAllowedApplications
        value.ignoredPasteboardTypes = try container.decodeIfPresent(
            Set<String>.self,
            forKey: .ignoredPasteboardTypes
        ) ?? value.ignoredPasteboardTypes
        value.ignoredTextPatterns = try container.decodeIfPresent(
            [String].self,
            forKey: .ignoredTextPatterns
        ) ?? value.ignoredTextPatterns
        value.capturePaused = try container.decodeIfPresent(Bool.self, forKey: .capturePaused)
            ?? value.capturePaused
        value.ignoreOnlyNextCapture = try container.decodeIfPresent(
            Bool.self,
            forKey: .ignoreOnlyNextCapture
        ) ?? value.ignoreOnlyNextCapture
        value.clipboardCheckInterval = try container.decodeIfPresent(
            Double.self,
            forKey: .clipboardCheckInterval
        ) ?? value.clipboardCheckInterval
        value.pasteWithoutFormatting = try container.decodeIfPresent(
            Bool.self,
            forKey: .pasteWithoutFormatting
        ) ?? value.pasteWithoutFormatting
        value.clearHistoryOnQuit = try container.decodeIfPresent(
            Bool.self,
            forKey: .clearHistoryOnQuit
        ) ?? value.clearHistoryOnQuit
        value.clearSystemClipboardOnQuit = try container.decodeIfPresent(
            Bool.self,
            forKey: .clearSystemClipboardOnQuit
        ) ?? value.clearSystemClipboardOnQuit
        value.searchMode = try container.decodeIfPresent(ClipboardSearchMode.self, forKey: .searchMode)
            ?? value.searchMode
        value.sortMode = try container.decodeIfPresent(ClipboardSortMode.self, forKey: .sortMode)
            ?? value.sortMode
        value.pinsPosition = try container.decodeIfPresent(
            ClipboardPinsPosition.self,
            forKey: .pinsPosition
        ) ?? value.pinsPosition
        value.popupPosition = try container.decodeIfPresent(
            ClipboardPopupPosition.self,
            forKey: .popupPosition
        ) ?? value.popupPosition
        value.popupScreen = try container.decodeIfPresent(Int.self, forKey: .popupScreen)
            ?? value.popupScreen
        value.openPreviewAutomatically = try container.decodeIfPresent(
            Bool.self,
            forKey: .openPreviewAutomatically
        ) ?? value.openPreviewAutomatically
        value.previewDelayMilliseconds = try container.decodeIfPresent(
            Int.self,
            forKey: .previewDelayMilliseconds
        ) ?? value.previewDelayMilliseconds
        value.previewWidth = try container.decodeIfPresent(Double.self, forKey: .previewWidth)
            ?? value.previewWidth
        value.imageRowHeight = try container.decodeIfPresent(Int.self, forKey: .imageRowHeight)
            ?? value.imageRowHeight
        value.highlightStyle = try container.decodeIfPresent(
            ClipboardHighlightStyle.self,
            forKey: .highlightStyle
        ) ?? value.highlightStyle
        value.showFooter = try container.decodeIfPresent(Bool.self, forKey: .showFooter)
            ?? value.showFooter
        value.showApplicationIcons = try container.decodeIfPresent(
            Bool.self,
            forKey: .showApplicationIcons
        ) ?? value.showApplicationIcons
        value.showSpecialSymbols = try container.decodeIfPresent(
            Bool.self,
            forKey: .showSpecialSymbols
        ) ?? value.showSpecialSymbols
        value.showHexColorSwatch = try container.decodeIfPresent(
            Bool.self,
            forKey: .showHexColorSwatch
        ) ?? value.showHexColorSwatch
        value.showRecentCopyInMenuBar = try container.decodeIfPresent(
            Bool.self,
            forKey: .showRecentCopyInMenuBar
        ) ?? value.showRecentCopyInMenuBar
        value.pinShortcut = try container.decodeIfPresent(GlobalShortcut.self, forKey: .pinShortcut)
            ?? value.pinShortcut
        value.deleteShortcut = try container.decodeIfPresent(
            GlobalShortcut.self,
            forKey: .deleteShortcut
        ) ?? value.deleteShortcut
        value.previewShortcut = try container.decodeIfPresent(
            GlobalShortcut.self,
            forKey: .previewShortcut
        ) ?? value.previewShortcut
        self = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(retentionPeriod, forKey: .retentionPeriod)
        try container.encode(itemLimitBytes, forKey: .itemLimitBytes)
        try container.encode(enabledStorageCategories, forKey: .enabledStorageCategories)
        try container.encode(ignoredBundleIdentifiers, forKey: .ignoredBundleIdentifiers)
        try container.encode(allowedBundleIdentifiers, forKey: .allowedBundleIdentifiers)
        try container.encode(
            captureOnlyFromAllowedApplications,
            forKey: .captureOnlyFromAllowedApplications
        )
        try container.encode(ignoredPasteboardTypes, forKey: .ignoredPasteboardTypes)
        try container.encode(ignoredTextPatterns, forKey: .ignoredTextPatterns)
        try container.encode(capturePaused, forKey: .capturePaused)
        try container.encode(ignoreOnlyNextCapture, forKey: .ignoreOnlyNextCapture)
        try container.encode(clipboardCheckInterval, forKey: .clipboardCheckInterval)
        try container.encode(pasteWithoutFormatting, forKey: .pasteWithoutFormatting)
        try container.encode(clearHistoryOnQuit, forKey: .clearHistoryOnQuit)
        try container.encode(clearSystemClipboardOnQuit, forKey: .clearSystemClipboardOnQuit)
        try container.encode(searchMode, forKey: .searchMode)
        try container.encode(sortMode, forKey: .sortMode)
        try container.encode(pinsPosition, forKey: .pinsPosition)
        try container.encode(popupPosition, forKey: .popupPosition)
        try container.encode(popupScreen, forKey: .popupScreen)
        try container.encode(openPreviewAutomatically, forKey: .openPreviewAutomatically)
        try container.encode(previewDelayMilliseconds, forKey: .previewDelayMilliseconds)
        try container.encode(previewWidth, forKey: .previewWidth)
        try container.encode(imageRowHeight, forKey: .imageRowHeight)
        try container.encode(highlightStyle, forKey: .highlightStyle)
        try container.encode(showFooter, forKey: .showFooter)
        try container.encode(showApplicationIcons, forKey: .showApplicationIcons)
        try container.encode(showSpecialSymbols, forKey: .showSpecialSymbols)
        try container.encode(showHexColorSwatch, forKey: .showHexColorSwatch)
        try container.encode(showRecentCopyInMenuBar, forKey: .showRecentCopyInMenuBar)
        try container.encode(pinShortcut, forKey: .pinShortcut)
        try container.encode(deleteShortcut, forKey: .deleteShortcut)
        try container.encode(previewShortcut, forKey: .previewShortcut)
    }
}

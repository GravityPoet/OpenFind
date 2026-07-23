import Foundation

extension ClipboardStorageCategory {
    var localizedTitle: String {
        switch self {
        case .text: L("Clipboard Storage Text")
        case .images: L("Clipboard Storage Images")
        case .files: L("Clipboard Storage Files")
        }
    }
}

extension ClipboardRetentionPeriod {
    var localizedTitle: String {
        switch self {
        case .days3: L("Clipboard Retention 3 Days")
        case .days7: L("Clipboard Retention 7 Days")
        case .days15: L("Clipboard Retention 15 Days")
        case .days30: L("Clipboard Retention 30 Days")
        case .forever: L("Clipboard Retention Forever")
        }
    }
}

extension ClipboardSearchMode {
    var localizedTitle: String {
        switch self {
        case .exact: L("Clipboard Search Exact")
        case .fuzzy: L("Clipboard Search Fuzzy")
        case .regularExpression: L("Clipboard Search Regex")
        case .mixed: L("Clipboard Search Mixed")
        }
    }
}

extension ClipboardSortMode {
    var localizedTitle: String {
        switch self {
        case .lastCopied: L("Clipboard Sort Last Copied")
        case .firstCopied: L("Clipboard Sort First Copied")
        }
    }
}

extension ClipboardPinsPosition {
    var localizedTitle: String {
        switch self {
        case .top: L("Clipboard Pins Top")
        case .bottom: L("Clipboard Pins Bottom")
        }
    }
}

extension ClipboardPopupPosition {
    var localizedTitle: String {
        switch self {
        case .cursor: L("Clipboard Popup Cursor")
        case .center: L("Clipboard Popup Center")
        case .lastPosition: L("Clipboard Popup Last Position")
        }
    }
}

extension ClipboardHighlightStyle {
    var localizedTitle: String {
        switch self {
        case .bold: L("Clipboard Highlight Bold")
        case .color: L("Clipboard Highlight Color")
        case .italic: L("Clipboard Highlight Italic")
        case .underline: L("Clipboard Highlight Underline")
        }
    }
}

extension ClipboardQuickMergeSeparator {
    var localizedTitle: String {
        switch self {
        case .newline: L("Quick Merge Separator Newline")
        case .space: L("Quick Merge Separator Space")
        case .none: L("Quick Merge Separator None")
        case .custom: L("Quick Merge Separator Custom")
        }
    }
}

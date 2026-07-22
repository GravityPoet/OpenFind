import Foundation

enum ClipboardPanelAction: String, Identifiable, Hashable, Sendable {
    case paste
    case pastePlainText
    case copy
    case copyPlainText
    case pasteSelection
    case pasteSelectionPlainText
    case mergeSelectionPlainText
    case openURL
    case openFiles
    case revealFiles
    case quickLookFiles
    case saveForReuse
    case removeFromSaved
    case delete
    case clearRecentFiveMinutes
    case clearRecentFifteenMinutes
    case clearUnpinned

    var id: Self { self }
}

struct ClipboardPanelActionContext: Equatable, Sendable {
    let entry: ClipboardEntry?
    let selectedEntries: [ClipboardEntry]
    let canCopyPlainText: Bool
    let canMergePlainText: Bool
    let hasOpenableURL: Bool
    let hasFiles: Bool

    var itemActions: [ClipboardPanelAction] {
        guard let entry else { return [] }
        if selectedEntries.count > 1 {
            var actions: [ClipboardPanelAction] = [.pasteSelection]
            if canMergePlainText {
                actions.append(.pasteSelectionPlainText)
                actions.append(.mergeSelectionPlainText)
            }
            actions.append(.delete)
            return actions
        }

        var actions: [ClipboardPanelAction] = [.paste]
        if canCopyPlainText { actions.append(.pastePlainText) }
        actions.append(.copy)
        if canCopyPlainText { actions.append(.copyPlainText) }
        if hasOpenableURL { actions.append(.openURL) }
        if hasFiles {
            actions.append(contentsOf: [.openFiles, .revealFiles, .quickLookFiles])
        }
        actions.append(entry.isPinned ? .removeFromSaved : .saveForReuse)
        actions.append(.delete)
        return actions
    }

    static let historyActions: [ClipboardPanelAction] = [
        .clearRecentFiveMinutes,
        .clearRecentFifteenMinutes,
        .clearUnpinned,
    ]
}

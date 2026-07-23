import SwiftUI

struct ClipboardActionPanel: View {
    let itemActions: [ClipboardPanelAction]
    let contentActions: [ClipboardContentActionDescriptor]
    let historyActions: [ClipboardPanelAction]
    let onPerform: (ClipboardPanelAction) -> Void
    let onPerformContentAction: (ClipboardContentActionDescriptor) -> Void
    let onDismiss: () -> Void
    @FocusState private var focusedActionID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !itemActions.isEmpty {
                actionSection(title: L("Selected Clipboard Item"), actions: itemActions)
                if !contentActions.isEmpty {
                    Divider()
                    contentActionSection
                }
                Divider()
            }
            actionSection(title: L("History Cleanup"), actions: historyActions)
        }
        .padding(10)
        .frame(width: 306)
        .background(.ultraThinMaterial)
        .onAppear { focusedActionID = allActionIDs.first }
        .onMoveCommand(perform: moveFocus)
        .onExitCommand(perform: onDismiss)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Clipboard Actions"))
    }

    private var allActionIDs: [String] {
        itemActions.map { "panel:\($0.rawValue)" }
            + contentActions.map { "content:\($0.id)" }
            + historyActions.map { "panel:\($0.rawValue)" }
    }

    private func actionSection(
        title: String,
        actions: [ClipboardPanelAction]
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.bottom, 2)

            ForEach(actions) { action in
                let focusID = "panel:\(action.rawValue)"
                Button(role: action.isDestructive ? .destructive : nil) {
                    onPerform(action)
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: action.systemImage)
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 18)
                        Text(action.localizedTitle)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if let shortcut = action.shortcutLabel {
                            Text(shortcut)
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 7)
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(action.isDestructive ? Color.red : Color.primary)
                .focused($focusedActionID, equals: focusID)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(focusedActionID == focusID ? Color.accentColor.opacity(0.14) : .clear)
                }
                .onHover { hovering in
                    if hovering { focusedActionID = focusID }
                }
                .accessibilityLabel(Text(action.localizedTitle))
                .accessibilityHint(Text(action.shortcutLabel ?? ""))
                .accessibilityIdentifier("clipboard.action.\(action.rawValue)")
            }
        }
    }

    private var contentActionSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L("Transform and Copy"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.bottom, 2)

            ForEach(contentActions) { action in
                let focusID = "content:\(action.id)"
                Button {
                    onPerformContentAction(action)
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: action.systemImage)
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 18)
                        Text(action.localizedTitle)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                    }
                    .padding(.horizontal, 7)
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focused($focusedActionID, equals: focusID)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(focusedActionID == focusID ? Color.accentColor.opacity(0.14) : .clear)
                }
                .onHover { hovering in
                    if hovering { focusedActionID = focusID }
                }
                .accessibilityLabel(Text(action.localizedTitle))
                .accessibilityIdentifier("clipboard.content-action.\(action.id)")
            }
        }
    }

    private func moveFocus(_ direction: MoveCommandDirection) {
        let actions = allActionIDs
        guard !actions.isEmpty else { return }
        let current = focusedActionID.flatMap { actions.firstIndex(of: $0) } ?? 0
        switch direction {
        case .up:
            focusedActionID = actions[max(0, current - 1)]
        case .down:
            focusedActionID = actions[min(actions.count - 1, current + 1)]
        default:
            break
        }
    }
}

private extension ClipboardPanelAction {
    var localizedTitle: String {
        switch self {
        case .paste: L("Paste")
        case .pastePlainText: L("Paste Plain Text")
        case .copy: L("Copy")
        case .copyPlainText: L("Copy Plain Text")
        case .pasteSelection: L("Paste Selected in Order")
        case .pasteSelectionPlainText: L("Paste Selected as Plain Text")
        case .mergeSelectionPlainText: L("Merge Selected and Copy")
        case .openURL: L("Open Link")
        case .openFiles: L("Open")
        case .revealFiles: L("Reveal in Finder")
        case .quickLookFiles: L("Quick Look")
        case .saveForReuse: L("Save for Reuse")
        case .removeFromSaved: L("Remove from Saved")
        case .delete: L("Delete")
        case .clearRecentFiveMinutes: L("Clear Last 5 Minutes")
        case .clearRecentFifteenMinutes: L("Clear Last 15 Minutes")
        case .clearUnpinned: L("Clear Unpinned Clipboard")
        }
    }

    var systemImage: String {
        switch self {
        case .paste, .pasteSelection: "return"
        case .pastePlainText, .pasteSelectionPlainText: "textformat"
        case .copy: "doc.on.doc"
        case .copyPlainText: "doc.plaintext"
        case .mergeSelectionPlainText: "arrow.triangle.merge"
        case .openURL: "safari"
        case .openFiles: "arrow.up.forward.app"
        case .revealFiles: "folder"
        case .quickLookFiles: "eye"
        case .saveForReuse: "pin.fill"
        case .removeFromSaved: "pin.slash"
        case .delete: "trash"
        case .clearRecentFiveMinutes, .clearRecentFifteenMinutes: "clock.arrow.circlepath"
        case .clearUnpinned: "trash.slash"
        }
    }

    var shortcutLabel: String? {
        switch self {
        case .paste, .pasteSelection: "↩"
        case .pastePlainText, .pasteSelectionPlainText: "⌥⇧↩"
        case .copy: "⌘C"
        case .copyPlainText: "⇧↩"
        case .saveForReuse: "⌘S"
        default: nil
        }
    }

    var isDestructive: Bool {
        switch self {
        case .delete, .clearRecentFiveMinutes, .clearRecentFifteenMinutes, .clearUnpinned:
            true
        default:
            false
        }
    }
}

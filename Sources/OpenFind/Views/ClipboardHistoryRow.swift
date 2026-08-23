import AppKit
import SwiftUI

struct ClipboardHistoryRow: View {
    let entry: ClipboardEntry
    let previewImage: NSImage?
    let sourceApplicationIcon: NSImage?
    let quickIndex: Int?
    let selectionOrder: Int?
    let searchPresentation: ClipboardSearchPresentation?
    let isSelected: Bool
    let query: String
    let preferences: ClipboardPreferences
    let canUsePlainText: Bool
    let isFrequentlyUsed: Bool
    let onUse: () -> Void
    let onHoverSelection: () -> Void
    let onCopy: () -> Void
    let onPaste: () -> Void
    let onPastePlainText: () -> Void
    let onEditNote: () -> Void
    let onToggleFrequentlyUsed: () -> Void
    let onPin: () -> Void
    let onDelete: () -> Void
    @State private var isHovered = false

    var body: some View {
        interactiveRow
            .contextMenu {
                rowContextMenu
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(entry.previewText)
            .accessibilityValue(Text(accessibilityValue))
            .accessibilityHint(Text(L("Press Return to Paste Clipboard Item")))
            .accessibilityAddTraits(.isButton)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityAction {
                onUse()
            }
            .accessibilityAction(named: Text(entry.isPinned ? L("Unpin") : L("Pin"))) {
                onPin()
            }
            .accessibilityAction(named: Text(entry.hasCustomTitle ? L("Edit Note") : L("Add Note"))) {
                onEditNote()
            }
            .accessibilityAction(named: Text(frequentlyUsedActionTitle)) {
                onToggleFrequentlyUsed()
            }
            .accessibilityAction(named: Text(L("Delete"))) {
                onDelete()
            }
    }

    private var interactiveRow: some View {
        HStack(spacing: 8) {
            if let selectionOrder {
                Text(selectionOrder.formatted())
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .frame(width: 18, height: 18)
                    .background(
                        isSelected
                            ? selectedTextColor.opacity(0.22)
                            : Color.accentColor.opacity(0.18),
                        in: Circle()
                    )
            }

            leadingIcon

            if let image = previewImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(
                        maxWidth: CGFloat(preferences.imageRowHeight) * 1.8,
                        maxHeight: CGFloat(preferences.imageRowHeight)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.6)
                    }
            }

            if preferences.showHexColorSwatch, let color = entry.hexColor {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(color)
                    .frame(width: 22, height: 22)
                    .overlay {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                    }
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(ClipboardHighlightedText.title(
                    for: entry,
                    query: query,
                    preferences: preferences
                ))
                    .font(isSelected
                        ? ClipboardTypography.selectedRow
                        : ClipboardTypography.row)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let note = ClipboardHighlightedText.note(
                    for: entry,
                    query: query,
                    preferences: preferences
                ) {
                    HStack(spacing: 3) {
                        Text(L("Clipboard Note Annotation"))
                            .fixedSize(horizontal: true, vertical: false)
                        Text(note)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .font(ClipboardTypography.matchContext)
                    .foregroundStyle(isSelected
                        ? selectedTextColor.opacity(0.88)
                        : ClipboardTypography.noteText)
                }

                if let searchPresentation,
                   let context = searchPresentation.context {
                    HStack(spacing: 5) {
                        Text(searchPresentation.field.localizedLabel)
                            .font(ClipboardTypography.matchLabel)
                            .fixedSize(horizontal: true, vertical: false)
                        Text(ClipboardHighlightedText.text(
                            context,
                            query: query,
                            preferences: preferences,
                            pointSize: ClipboardTypography.matchContextPointSize
                        ))
                            .font(ClipboardTypography.matchContext)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .foregroundStyle(isSelected
                        ? selectedTextColor.opacity(0.78)
                        : ClipboardTypography.secondaryText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if entry.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(isSelected
                        ? selectedTextColor.opacity(0.90)
                        : Color.accentColor.opacity(0.68))
                if let pin = ClipboardPinKey.normalize(entry.pinKey) {
                    shortcutChip("⌘\(pin.uppercased())")
                }
            }

            if let quickIndex {
                shortcutChip("⌘\(quickIndex)")
            }
        }
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
        .foregroundStyle(isSelected ? selectedTextColor : ClipboardTypography.primaryText)
        .modifier(ClipboardHistoryRowSurface(
            isSelected: isSelected,
            isHovered: isHovered
        ))
        .contentShape(Rectangle())
        .onTapGesture(perform: onUse)
        .onHover { hovering in
            isHovered = hovering
            if hovering { onHoverSelection() }
        }
        .help(sourceHelp)
    }

    @ViewBuilder
    private var leadingIcon: some View {
        if preferences.showApplicationIcons, let icon = sourceApplicationIcon {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
                .frame(width: 22, height: 22)
                .frame(width: 26, height: 26)
        } else if previewImage == nil {
            Image(systemName: entry.kind.systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isSelected ? selectedTextColor : Color.secondary)
                .frame(width: 22, height: 22)
                .background(
                    isSelected
                        ? selectedTextColor.opacity(0.16)
                        : Color.secondary.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                )
        }
    }

    private func shortcutChip(_ text: String) -> some View {
        Text(text)
            .font(ClipboardTypography.shortcut)
            .monospacedDigit()
            .foregroundStyle(isSelected
                ? selectedTextColor.opacity(0.96)
                : ClipboardTypography.secondaryText)
            .padding(.horizontal, 5)
            .frame(minWidth: 24, minHeight: 18)
            .background(
                isSelected
                    ? selectedTextColor.opacity(0.13)
                    : Color.primary.opacity(0.05),
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
    }

    private var rowHeight: CGFloat {
        let secondaryLineCount = (entry.hasCustomTitle ? 1 : 0)
            + (searchPresentation?.context == nil ? 0 : 1)
        let contentHeight: CGFloat = switch secondaryLineCount {
        case 0: 30
        case 1: 43
        default: 56
        }
        guard previewImage != nil else { return contentHeight }
        return max(contentHeight, CGFloat(preferences.imageRowHeight + 8))
    }

    @ViewBuilder
    private var rowContextMenu: some View {
        Button(L("Copy"), action: onCopy)
        Button(L("Paste"), action: onPaste)
        Button(L("Paste Plain Text"), action: onPastePlainText)
            .disabled(!canUsePlainText)
        Divider()
        Button(entry.hasCustomTitle ? L("Edit Note") : L("Add Note"), action: onEditNote)
        Button(frequentlyUsedActionTitle, action: onToggleFrequentlyUsed)
        Button(entry.isPinned ? L("Unpin") : L("Pin"), action: onPin)
        Divider()
        Button(L("Delete"), role: .destructive, action: onDelete)
    }

    private var frequentlyUsedActionTitle: String {
        isFrequentlyUsed ? L("Remove from Frequently Used") : L("Add to Frequently Used")
    }

    private var selectedTextColor: Color {
        Color(nsColor: .selectedControlTextColor)
    }

    private var sourceHelp: String {
        guard let source = entry.sourceApplicationName ?? entry.sourceBundleIdentifier else {
            return entry.kind.localizedTitle
        }
        return "\(L("Source Application")): \(source)"
    }

    private var accessibilityValue: String {
        var components: [String] = []
        if let note = entry.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !note.isEmpty {
            components.append("\(L("Clipboard Note Annotation")) \(note)")
        }
        if let searchPresentation,
           let context = searchPresentation.context {
            components.append("\(searchPresentation.field.localizedLabel): \(context)")
        }
        components.append(sourceHelp)
        return components.joined(separator: ". ")
    }

}

private struct ClipboardHistoryRowSurface: ViewModifier {
    let isSelected: Bool
    let isHovered: Bool
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    @ViewBuilder
    func body(content: Content) -> some View {
        if isSelected {
            content
                .background(
                    Color(nsColor: .selectedContentBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(
                            Color(nsColor: .selectedControlTextColor)
                                .opacity(colorSchemeContrast == .increased ? 0.72 : 0.24),
                            lineWidth: colorSchemeContrast == .increased ? 1.2 : 0.7
                        )
                }
        } else {
            content.background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isHovered
                        ? Color.primary.opacity(colorSchemeContrast == .increased ? 0.12 : 0.055)
                        : .clear)
            }
        }
    }
}

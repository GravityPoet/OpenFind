import SwiftUI

struct ClipboardHistoryRow: View {
    let entry: ClipboardEntry
    let previewImage: NSImage?
    let sourceApplicationIcon: NSImage?
    let quickIndex: Int?
    let selectionOrder: Int?
    let isSelected: Bool
    let query: String
    let preferences: ClipboardPreferences
    let canUsePlainText: Bool
    let onUse: () -> Void
    let onHoverSelection: () -> Void
    let onCopy: () -> Void
    let onPaste: () -> Void
    let onPastePlainText: () -> Void
    let onPin: () -> Void
    let onDelete: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            if let selectionOrder {
                Text(selectionOrder.formatted())
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .frame(width: 18, height: 18)
                    .background(
                        isSelected ? Color.white.opacity(0.22) : Color.accentColor.opacity(0.18),
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

            Text(ClipboardHighlightedText.title(
                for: entry,
                query: query,
                preferences: preferences
            ))
                .font(ClipboardTypography.row)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            if entry.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .opacity(isSelected ? 0.9 : 0.48)
                if let pin = ClipboardPinKey.normalize(entry.pinKey) {
                    Text("⌘\(pin.uppercased())")
                        .font(ClipboardTypography.shortcut)
                        .foregroundStyle(isSelected
                            ? Color.white.opacity(0.96)
                            : ClipboardTypography.secondaryText)
                }
            }

            if let quickIndex {
                Text("⌘\(quickIndex)")
                    .font(ClipboardTypography.shortcut)
                    .monospacedDigit()
                    .foregroundStyle(isSelected
                        ? Color.white.opacity(0.96)
                        : ClipboardTypography.secondaryText)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
        .foregroundStyle(isSelected ? Color.white : ClipboardTypography.primaryText)
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
        .contextMenu {
            Button(L("Copy"), action: onCopy)
            Button(L("Paste"), action: onPaste)
            Button(L("Paste Plain Text"), action: onPastePlainText)
                .disabled(!canUsePlainText)
            Divider()
            Button(entry.isPinned ? L("Unpin") : L("Pin"), action: onPin)
            Button(L("Delete"), role: .destructive, action: onDelete)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry.displayTitle)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var leadingIcon: some View {
        if preferences.showApplicationIcons, let icon = sourceApplicationIcon {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
                .frame(width: 21, height: 21)
                .frame(width: 24, height: 24)
        } else if previewImage == nil {
            Image(systemName: entry.kind.systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isSelected ? Color.white : Color.secondary)
                .frame(width: 22, height: 22)
                .background(
                    isSelected ? Color.white.opacity(0.16) : Color.secondary.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                )
        }
    }

    private var rowHeight: CGFloat {
        previewImage == nil ? 30 : CGFloat(preferences.imageRowHeight + 8)
    }

    private var sourceHelp: String {
        guard let source = entry.sourceApplicationName ?? entry.sourceBundleIdentifier else {
            return entry.kind.localizedTitle
        }
        return "\(L("Source Application")): \(source)"
    }

}

private struct ClipboardHistoryRowSurface: ViewModifier {
    let isSelected: Bool
    let isHovered: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isSelected {
            content
                .openFindSelectedGlassRoundedRectangle(cornerRadius: 8)
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.7)
                }
        } else {
            content.background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(0.055) : .clear)
            }
        }
    }
}

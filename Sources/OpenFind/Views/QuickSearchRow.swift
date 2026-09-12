import SwiftUI

struct QuickSearchRow: View {
    let item: QuickSearchItem
    let index: Int
    let isSelected: Bool
    let scale: CGFloat
    let onOpen: () -> Void
    @State private var isHovered = false
    @State private var icon: NSImage?
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12 * scale) {
                Group {
                    if let icon { Image(nsImage: icon).resizable() }
                    else {
                        Image(systemName: item.isSystemSetting ? "gearshape" : item.isApplication ? "app" : "doc")
                            .resizable().foregroundStyle(.secondary)
                    }
                }
                .scaledToFit()
                .frame(width: 32 * scale, height: 32 * scale)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3 * scale) {
                    Text(item.name)
                        .font(.system(size: 15 * scale, weight: .medium))
                        .foregroundStyle(.primary).lineLimit(1)
                    Text((item.location as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: 11 * scale))
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 6)
                if item.isApplication || item.isSystemSetting {
                    Text(item.isSystemSetting ? L("System Settings") : L("Quick Search App"))
                        .font(.system(size: 10 * scale)).foregroundStyle(.secondary)
                }
                if index < 9 {
                    Text("⌘\(index + 1)")
                        .font(.system(size: 11 * scale, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14 * scale)
            .frame(height: 56 * scale)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 14 * scale, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.12)
                      : Color.primary.opacity(isHovered ? 0.045 : 0))
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 14 * scale, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(contrast == .increased ? 0.8 : 0.18))
                    }
                }
        }
        .onHover { isHovered = $0 }
        .accessibilityLabel(item.name)
        .accessibilityHint(item.location)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .task(id: item.url) {
            icon = item.isSystemSetting ? NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
                : FileIcon.icon(for: item.url, size: 32)
        }
    }
}

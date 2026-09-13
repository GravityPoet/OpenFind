import SwiftUI

struct QuickSearchRow: View {
    let item: QuickSearchItem
    let index: Int
    let isSelected: Bool
    let scale: CGFloat
    let onOpen: () -> Void
    var onRecentDocuments: () -> Void = {}
    var onQuickLook: () -> Void = {}
    @State private var isHovered = false
    @State private var icon: NSImage?
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12 * scale) {
                Group {
                    if let icon { Image(nsImage: icon).resizable() }
                    else {
                        Image(systemName: item.symbolName)
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
        .contextMenu {
            Button(L("Open"), action: onOpen)
            if item.url.isFileURL {
                Button(L("Reveal in Finder")) { FileActions.revealInFinder([item.url]) }
                Button(L("Quick Look"), action: onQuickLook)
                Button(L("Copy Path")) { FileActions.copyPaths([item.url]) }
                Button(L("Copy File Name")) { FileActions.copyFileNames([item.url]) }
                Button(L("Copy File")) { FileActions.copyFiles([item.url]) }
            } else if item.kind == .bookmark || item.kind == .web {
                Button(L("Copy Link")) { FileActions.copyPathStrings([item.url.absoluteString]) }
            }
            if item.isApplication {
                Divider()
                Button(L("Recent Documents"), action: onRecentDocuments)
            }
        }
        .task(id: item.url) {
            icon = item.url.isFileURL ? FileIcon.icon(for: item.url, size: 32 * scale)
                : NSImage(systemSymbolName: item.symbolName, accessibilityDescription: nil)
        }
    }
}

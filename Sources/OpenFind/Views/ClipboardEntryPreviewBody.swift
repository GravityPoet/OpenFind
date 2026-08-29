import AppKit
import SwiftUI

enum ClipboardEntryPreviewMetrics {
    static let bodyInsets = EdgeInsets(
        top: 20,
        leading: 22,
        bottom: 20,
        trailing: 22
    )
}

struct ClipboardEntryPreviewBody: View {
    let entry: ClipboardEntry
    let previewImage: NSImage?

    var body: some View {
        if let image = previewImage {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.8)
                }
                .shadow(color: .black.opacity(0.11), radius: 14, y: 4)
                .frame(maxHeight: 440, alignment: .top)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else if entry.kind == .file, !entry.fileURLs.isEmpty {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(entry.fileURLs, id: \.absoluteString) { fileURL in
                        HStack(spacing: 12) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: fileURL.path))
                                .resizable()
                                .scaledToFit()
                                .frame(width: 36, height: 36)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(fileURL.lastPathComponent)
                                    .font(.headline)
                                    .lineLimit(1)
                                Text(fileURL.deletingLastPathComponent().path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(10)
                        .background(
                            Color.primary.opacity(0.035),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                    }
                }
                .padding(18)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let url = entry.webURL {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        Image(systemName: "link")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 36, height: 36)
                            .background(
                                Color.accentColor.opacity(0.11),
                                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                            )

                        VStack(alignment: .leading, spacing: 2) {
                            Text(linkTitle(for: url))
                                .font(.system(size: 17, weight: .semibold))
                                .lineLimit(1)
                            Text(url.scheme?.uppercased() ?? L("Link"))
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Divider()

                    adaptiveLinkText(url.absoluteString)
                }
                .padding(ClipboardEntryPreviewMetrics.bodyInsets)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if entry.hasCustomTitle {
                        Text(entry.displayTitle)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(ClipboardTypography.primaryText)

                        Divider()
                    }

                    Text(entry.fullPreviewText)
                        .font(ClipboardTypography.preview)
                        .foregroundStyle(ClipboardTypography.primaryText)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(ClipboardEntryPreviewMetrics.bodyInsets)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private func linkTitle(for url: URL) -> String {
        if entry.hasCustomTitle { return entry.displayTitle }
        return url.host ?? entry.kind.localizedTitle
    }

    /// Keep a final short path component from being orphaned on a second line.
    /// The content inset remains symmetric; only medium-length links step down
    /// one readable size, while genuinely long links still wrap normally.
    private func adaptiveLinkText(_ value: String) -> some View {
        ViewThatFits(in: .horizontal) {
            linkText(value, size: 15.5)
                .fixedSize(horizontal: true, vertical: false)

            linkText(value, size: 14)
                .fixedSize(horizontal: true, vertical: false)

            linkText(value, size: 15.5)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func linkText(_ value: String, size: CGFloat) -> some View {
        Text(value)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(ClipboardTypography.primaryText)
            .lineSpacing(4)
            .textSelection(.enabled)
    }
}

import AppKit
import SwiftUI

struct ClipboardEntryMetadata: View {
    let entry: ClipboardEntry
    let sourceApplicationIcon: NSImage?
    let imageDimensions: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                sourceIdentity

                Spacer(minLength: 10)

                Text(contentDetails.joined(separator: "  ·  "))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.88)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }

            Divider()
                .opacity(0.55)

            HStack(spacing: 12) {
                Text(lastCopiedDescription)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if entry.initialCopiedAt != entry.createdAt {
                    Text(firstCopiedDescription)
                        .lineLimit(1)
                }
            }
            .font(.system(size: 10.5, weight: .regular))
            .foregroundStyle(.tertiary)

            if entry.numberOfUses > 0, let lastUsedAt = entry.lastUsedAt {
                Text(
                    String(
                        format: L("Clipboard Use Count Compact"),
                        entry.numberOfUses
                    )
                    + "  ·  "
                    + L("Last Used")
                    + " "
                    + lastUsedAt.formatted(date: .abbreviated, time: .shortened)
                )
                .font(.system(size: 10.5, weight: .regular))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private var sourceIdentity: some View {
        HStack(spacing: 9) {
            if let icon = sourceApplicationIcon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                    .frame(width: 28, height: 28)
            } else {
                Image(systemName: entry.kind.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(
                        Color.primary.opacity(0.055),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
            }

            if let sourceName {
                VStack(alignment: .leading, spacing: 2) {
                    Text(sourceName)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(ClipboardTypography.primaryText)
                        .lineLimit(1)
                    if let sourceDetail {
                        Text(sourceDetail)
                            .font(.system(size: 10.5, weight: .regular))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            } else {
                Text(entry.kind.localizedTitle)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: 175, alignment: .leading)
        .layoutPriority(1)
    }

    private var contentDetails: [String] {
        var details: [String] = []
        if let recognizedText = entry.recognizedText, !recognizedText.isEmpty {
            details.append(String(
                format: L("Clipboard Recognized Text Count"),
                recognizedText.count
            ))
        }
        if let statistics = entry.textStatistics {
            details.append(String(
                format: L("Clipboard Text Statistics"),
                statistics.words,
                statistics.characters
            ))
        }
        if let imageDimensions {
            details.append(imageDimensions)
        }
        details.append(entry.payloadByteCount.formatted(.byteCount(style: .file)))
        if entry.numberOfCopies > 1 {
            details.append(String(
                format: L("Clipboard Copy Count Compact"),
                entry.numberOfCopies
            ))
        }
        return details
    }

    private var lastCopiedDescription: String {
        L("Last Copied")
            + " "
            + entry.createdAt.formatted(date: .abbreviated, time: .shortened)
    }

    private var firstCopiedDescription: String {
        L("First Copied")
            + " "
            + entry.initialCopiedAt.formatted(date: .abbreviated, time: .shortened)
    }

    private var sourceName: String? {
        entry.sourceApplicationName ?? entry.sourceBundleIdentifier
    }

    private var sourceDetail: String? {
        guard entry.sourceApplicationName != nil else { return nil }
        return entry.sourceBundleIdentifier
    }
}

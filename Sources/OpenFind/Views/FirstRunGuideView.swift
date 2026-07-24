import SwiftUI

struct FirstRunGuideView: View {
    let capabilities: [FirstRunCapability]
    var copy = FirstRunGuideCopy.localized
    let onStartSearching: () -> Void
    let onOpenSettings: () -> Void
    let onDismiss: () -> Void
    @Environment(\.openFindInterfaceSize) private var interfaceSize

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            VStack(spacing: 8 * interfaceSize.scale) {
                ForEach(capabilities) { capability in
                    capabilityRow(capability)
                }
            }
            .padding(.top, 20 * interfaceSize.scale)

            Divider()
                .padding(.vertical, 18 * interfaceSize.scale)

            footer
        }
        .padding(24 * interfaceSize.scale)
        .frame(width: 620 * interfaceSize.scale)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14 * interfaceSize.scale) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 26 * interfaceSize.scale, weight: .semibold))
                .foregroundStyle(.white)
                .frame(
                    width: 52 * interfaceSize.scale,
                    height: 52 * interfaceSize.scale
                )
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 13))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5 * interfaceSize.scale) {
                Text(copy.title)
                    .font(.title2.weight(.semibold))

                Text(copy.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .frame(width: 24, height: 24)
                    .background(.quaternary, in: Circle())
            }
            .buttonStyle(.plain)
            .help(copy.dismiss)
            .accessibilityLabel(copy.dismiss)
        }
    }

    private func capabilityRow(_ capability: FirstRunCapability) -> some View {
        HStack(spacing: 12 * interfaceSize.scale) {
            Image(systemName: capability.systemImage)
                .font(.system(.body, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(
                    width: 32 * interfaceSize.scale,
                    height: 32 * interfaceSize.scale
                )
                .background(Color.accentColor.opacity(0.11), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(capability.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)

                Text(capability.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 10)

            Text(capability.shortcut)
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9 * interfaceSize.scale)
                .padding(.vertical, 5 * interfaceSize.scale)
                .background(Color.primary.opacity(0.07), in: Capsule())
                .fixedSize()
                .accessibilityLabel(
                    String(format: copy.shortcutFormat, capability.shortcut)
                )
        }
        .padding(.horizontal, 12 * interfaceSize.scale)
        .padding(.vertical, 9 * interfaceSize.scale)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 10 * interfaceSize.scale) {
            Text(copy.reopenHelp)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer(minLength: 12)

            Button(copy.openSettings, action: onOpenSettings)
                .buttonStyle(.bordered)

            Button(copy.startSearching, action: onStartSearching)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
    }
}

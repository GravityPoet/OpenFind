import SwiftUI

/// Stable slots separate selection from the text bounds and pointer hover.
struct SettingsNavigationBar: View {
    @Binding var selection: SettingsPane
    @Environment(\.openFindInterfaceSize) private var interfaceSize
    @FocusState private var focusedPane: SettingsPane?

    var body: some View {
        HStack(spacing: 2 * interfaceSize.scale) {
            ForEach(SettingsPane.navigationOrder) { pane in
                SettingsNavigationButton(
                    pane: pane, isSelected: selection == pane,
                    isFocused: focusedPane == pane, scale: interfaceSize.scale
                ) {
                    selection = pane
                    focusedPane = pane
                }
                .focusable()
                .focusEffectDisabled()
                .focused($focusedPane, equals: pane)
            }
        }
        .padding(4 * interfaceSize.scale)
        .openFindGlassCapsule()
        .frame(maxWidth: 760 * interfaceSize.scale)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Settings"))
        .onMoveCommand { direction in
            guard let focusedPane,
                  let index = SettingsPane.navigationOrder.firstIndex(of: focusedPane) else { return }
            let offset: Int
            switch direction {
            case .left: offset = -1
            case .right: offset = 1
            default: return
            }
            let next = min(max(index + offset, 0), SettingsPane.navigationOrder.count - 1)
            selection = SettingsPane.navigationOrder[next]
            self.focusedPane = selection
        }
    }
}

private struct SettingsNavigationButton: View {
    let pane: SettingsPane
    let isSelected: Bool
    let isFocused: Bool
    let scale: CGFloat
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Button(action: action) {
            Text(pane.label)
                .font(.system(size: 13 * scale, weight: .medium))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.horizontal, 8 * scale)
                .frame(maxWidth: .infinity)
                .frame(height: 34 * scale)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background {
            if isSelected {
                Capsule()
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.24 : 0.10),
                            radius: 2, y: 1)
                    .overlay {
                        Capsule().strokeBorder(
                            Color.primary.opacity(contrast == .increased ? 0.65 : 0.07),
                            lineWidth: 1
                        )
                    }
            } else {
                Capsule().fill(Color.primary.opacity(isHovered ? 0.045 : 0))
            }
        }
        .overlay {
            if isFocused {
                Capsule().strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1.5)
            }
        }
        .onHover { isHovered = $0 }
        .accessibilityLabel(pane.label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("OpenFind.settings.tab.\(pane.rawValue)")
    }
}

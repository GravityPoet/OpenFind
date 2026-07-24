import SwiftUI

struct ProductQuickActions: View {
    let onShowClipboardHistory: () -> Void
    let onShowMenuBar: () -> Void
    let onShowSettings: () -> Void
    @Environment(\.openFindInterfaceSize) private var interfaceSize

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8 * interfaceSize.scale) {
                actions
            }

            VStack(spacing: 7 * interfaceSize.scale) {
                actions
            }
        }
        .buttonStyle(.bordered)
    }

    @ViewBuilder
    private var actions: some View {
        Button(action: onShowClipboardHistory) {
            Label(L("Clipboard History"), systemImage: "doc.on.clipboard")
        }

        Button(action: onShowMenuBar) {
            Label(L("Menu Bar Controls"), systemImage: "menubar.rectangle")
        }

        Button(action: onShowSettings) {
            Label(L("Settings"), systemImage: "gearshape")
        }
    }
}

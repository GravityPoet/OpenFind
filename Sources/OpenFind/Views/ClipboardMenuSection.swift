import SwiftUI

struct ClipboardMenuSection: View {
    @Bindable var store: ClipboardHistoryStore
    @Bindable var controller: ClipboardController

    var body: some View {
        Button {
            controller.showWindow()
        } label: {
            Label(L("Clipboard History"), systemImage: "doc.on.clipboard")
        }

        if store.preferences.showRecentCopyInMenuBar, let latestEntry {
            Label {
                Text(latestEntry.displayTitle.replacingOccurrences(of: "\n", with: " "))
                    .lineLimit(1)
            } icon: {
                if let icon = latestEntry.sourceApplicationIcon {
                    Image(nsImage: icon)
                } else {
                    Image(systemName: latestEntry.kind.systemImage)
                }
            }
            .help(L("Latest Clipboard Copy"))
        }

        Toggle(
            L("Pause Clipboard Capture"),
            isOn: Binding(
                get: { store.preferences.capturePaused },
                set: { store.setCapturePaused($0) }
            )
        )

        Button(L("Ignore Next Clipboard Copy")) {
            store.ignoreNextCapture()
        }
        .disabled(store.preferences.ignoreOnlyNextCapture)

        if case .conflict = controller.registrationState {
            Text(L("Clipboard Shortcut Conflicts"))
                .foregroundStyle(.orange)
        }
    }

    private var latestEntry: ClipboardEntry? {
        store.entries.max { $0.createdAt < $1.createdAt }
    }
}

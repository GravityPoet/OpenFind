import SwiftUI

struct ClipboardCaptureSettings: View {
    @Bindable var store: ClipboardHistoryStore
    @State private var showingIgnoreRules = false

    var body: some View {
        Toggle(
            L("Pause Clipboard Capture"),
            isOn: Binding(
                get: { store.preferences.capturePaused },
                set: { store.setCapturePaused($0) }
            )
        )

        HStack {
            Button(L("Ignore Next Clipboard Copy")) {
                store.ignoreNextCapture()
            }
            .disabled(store.preferences.ignoreOnlyNextCapture)

            if store.preferences.ignoreOnlyNextCapture {
                Label(L("Waiting for Next Clipboard Copy"), systemImage: "hourglass")
                    .foregroundStyle(.secondary)
            }
        }

        Button {
            showingIgnoreRules = true
        } label: {
            HStack {
                Text(L("Manage Clipboard Ignore Rules"))
                Spacer()
                Text(ignoreRuleCount.formatted())
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showingIgnoreRules) {
            ClipboardIgnoreRulesSheet(store: store)
        }
    }

    private var ignoreRuleCount: Int {
        store.preferences.ignoredBundleIdentifiers.count
            + store.preferences.ignoredPasteboardTypes.count
            + store.preferences.ignoredTextPatterns.count
    }
}

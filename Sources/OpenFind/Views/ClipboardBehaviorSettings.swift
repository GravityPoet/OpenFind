import SwiftUI

struct ClipboardBehaviorSettings: View {
    @Bindable var store: ClipboardHistoryStore
    @Bindable var controller: ClipboardController

    var body: some View {
        Toggle(
            L("Paste Without Formatting"),
            isOn: Binding(
                get: { store.pasteWithoutFormatting },
                set: { store.setPasteWithoutFormatting($0) }
            )
        )

        Picker(L("Clipboard Search Mode"), selection: Binding(
            get: { store.searchMode },
            set: { store.setSearchMode($0) }
        )) {
            ForEach(ClipboardSearchMode.allCases) { mode in
                Text(mode.localizedTitle).tag(mode)
            }
        }

        VStack(alignment: .leading, spacing: 4) {
            Picker(L("Clipboard Check Interval"), selection: Binding(
                get: { store.clipboardCheckInterval },
                set: { controller.setClipboardCheckInterval($0) }
            )) {
                Text("100 ms").tag(0.1)
                Text("250 ms").tag(0.25)
                Text(L("Clipboard Check Interval Recommended")).tag(0.5)
                Text("1 s").tag(1.0)
                Text("2 s").tag(2.0)
            }
            Text(L("Clipboard Check Interval Help"))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }

        Toggle(
            L("Clear Clipboard History On Quit"),
            isOn: Binding(
                get: { store.clearHistoryOnQuit },
                set: { store.setClearHistoryOnQuit($0) }
            )
        )
        Toggle(
            L("Clear System Clipboard On Quit"),
            isOn: Binding(
                get: { store.clearSystemClipboardOnQuit },
                set: { store.setClearSystemClipboardOnQuit($0) }
            )
        )

        shortcutSettings

        ClipboardActionShortcutSettings(store: store)
    }

    private var shortcutSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Toggle(
                    L("Clipboard Shortcut"),
                    isOn: Binding(
                        get: { controller.isShortcutEnabled },
                        set: { controller.setShortcutEnabled($0) }
                    )
                )
                Spacer()
                ShortcutRecorder(
                    shortcut: controller.shortcut,
                    prompt: L("Press Shortcut"),
                    accessibilityLabel: L("Clipboard Shortcut")
                ) { shortcut in
                    _ = controller.setShortcut(shortcut)
                }
                .frame(width: 112)
                if controller.shortcut != ClipboardController.defaultShortcut {
                    Button {
                        controller.resetShortcut()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.borderless)
                    .help(L("Restore Default Shortcut"))
                }
            }
            shortcutStatus
        }
    }

    @ViewBuilder
    private var shortcutStatus: some View {
        switch controller.registrationState {
        case .registered:
            Label(L("Clipboard Shortcut Registered"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .conflict:
            Label(L("Clipboard Shortcut Conflicts"), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .failed:
            Label(L("Clipboard Shortcut Unavailable"), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .disabled:
            EmptyView()
        }
    }
}

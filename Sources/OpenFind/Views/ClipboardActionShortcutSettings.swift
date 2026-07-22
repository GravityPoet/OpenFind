import SwiftUI

struct ClipboardActionShortcutSettings: View {
    @Bindable var store: ClipboardHistoryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Clipboard Action Shortcuts"))
                .font(.subheadline.weight(.semibold))

            shortcutRow(
                title: L("Clipboard Pin Shortcut"),
                keyPath: \.pinShortcut,
                defaultValue: ClipboardPreferences.defaultPinShortcut
            )
            shortcutRow(
                title: L("Clipboard Delete Shortcut"),
                keyPath: \.deleteShortcut,
                defaultValue: ClipboardPreferences.defaultDeleteShortcut
            )
            shortcutRow(
                title: L("Clipboard Preview Shortcut"),
                keyPath: \.previewShortcut,
                defaultValue: ClipboardPreferences.defaultPreviewShortcut
            )
        }
    }

    private func shortcutRow(
        title: String,
        keyPath: WritableKeyPath<ClipboardPreferences, GlobalShortcut>,
        defaultValue: GlobalShortcut
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
            Spacer()
            ShortcutRecorder(
                shortcut: store.preferences[keyPath: keyPath],
                prompt: L("Press Shortcut"),
                accessibilityLabel: title
            ) { shortcut in
                store.setPreference(keyPath, to: shortcut)
            }
            .frame(width: 112)
            Button {
                store.setPreference(keyPath, to: defaultValue)
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.borderless)
            .help(L("Restore Default Shortcut"))
            .disabled(store.preferences[keyPath: keyPath] == defaultValue)
        }
    }
}

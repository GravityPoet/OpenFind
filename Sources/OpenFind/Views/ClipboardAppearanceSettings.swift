import AppKit
import SwiftUI

struct ClipboardAppearanceSettings: View {
    @Bindable var store: ClipboardHistoryStore

    var body: some View {
        Picker(L("Clipboard Popup Position"), selection: preference(\.popupPosition)) {
            ForEach(ClipboardPopupPosition.allCases) { position in
                Text(position.localizedTitle).tag(position)
            }
        }

        if store.preferences.popupPosition != .cursor {
            Picker(L("Clipboard Popup Screen"), selection: preference(\.popupScreen)) {
                Text(L("Active Screen")).tag(0)
                ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { index, screen in
                    Text(screen.localizedName).tag(index + 1)
                }
            }
        }

        Toggle(
            L("Clipboard Open Preview Automatically"),
            isOn: preference(\.openPreviewAutomatically)
        )
        Stepper(
            value: preference(\.previewDelayMilliseconds),
            in: 200...5_000,
            step: 100
        ) {
            LabeledContent(L("Clipboard Preview Delay")) {
                Text("\(store.preferences.previewDelayMilliseconds) ms")
                    .monospacedDigit()
            }
        }
        .disabled(!store.preferences.openPreviewAutomatically)

        Stepper(value: preference(\.imageRowHeight), in: 16...120, step: 4) {
            LabeledContent(L("Clipboard Image Row Height")) {
                Text("\(store.preferences.imageRowHeight) pt")
                    .monospacedDigit()
            }
        }

        Picker(L("Clipboard Match Highlight"), selection: preference(\.highlightStyle)) {
            ForEach(ClipboardHighlightStyle.allCases) { style in
                Text(style.localizedTitle).tag(style)
            }
        }

        Toggle(L("Clipboard Show Footer"), isOn: preference(\.showFooter))
        Toggle(L("Clipboard Show Application Icons"), isOn: preference(\.showApplicationIcons))
        Toggle(L("Clipboard Show Special Symbols"), isOn: preference(\.showSpecialSymbols))
        Toggle(L("Clipboard Show Hex Color Swatch"), isOn: preference(\.showHexColorSwatch))
        Toggle(L("Clipboard Show Recent Copy In Menu"), isOn: preference(\.showRecentCopyInMenuBar))
    }

    private func preference<Value>(
        _ keyPath: WritableKeyPath<ClipboardPreferences, Value>
    ) -> Binding<Value> {
        Binding(
            get: { store.preferences[keyPath: keyPath] },
            set: { store.setPreference(keyPath, to: $0) }
        )
    }
}

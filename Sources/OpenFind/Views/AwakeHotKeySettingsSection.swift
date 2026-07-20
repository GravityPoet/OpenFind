import SwiftUI

struct AwakeHotKeySettingsSection: View {
    @Bindable var controller: AwakeHotKeyController

    var body: some View {
        Section {
            ForEach(AwakeHotKeyAction.allCases) { action in
                if let binding = controller.binding(for: action) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Toggle(
                                action.displayName,
                                isOn: Binding(
                                    get: { binding.isEnabled },
                                    set: { controller.setEnabled($0, for: action) }
                                )
                            )
                            Spacer(minLength: 6)
                            ShortcutRecorder(
                                shortcut: binding.shortcut,
                                prompt: L("Press Shortcut"),
                                accessibilityLabel: action.displayName
                            ) { shortcut in
                                controller.setShortcut(shortcut, for: action)
                            }
                            .frame(width: 112)
                            if binding.shortcut != action.defaultShortcut {
                                Button {
                                    controller.resetShortcut(for: action)
                                } label: {
                                    Image(systemName: "arrow.counterclockwise")
                                }
                                .buttonStyle(.borderless)
                                .help(L("Restore Default Shortcut"))
                            }
                        }

                        switch binding.registrationState {
                        case .conflict:
                            Label(L("Shortcut Conflicts"), systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.footnote)
                        case .failed:
                            Label(L("Shortcut Unavailable"), systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.footnote)
                        case .disabled, .registered:
                            EmptyView()
                        }
                    }
                }
            }
        } header: {
            Text(L("Awake Session Hotkeys"))
        } footer: {
            Text(L("Awake Session Hotkeys Help"))
        }
    }
}

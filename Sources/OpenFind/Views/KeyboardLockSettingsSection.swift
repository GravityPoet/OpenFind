import SwiftUI

struct KeyboardLockSettingsSection: View {
    @Bindable var controller: KeyboardLockController

    var body: some View {
        Section {
            Toggle(
                L("Keyboard Lock"),
                isOn: Binding(
                    get: { controller.isEngaged },
                    set: { enabled in
                        if enabled { controller.enable() } else { controller.disable() }
                    }
                )
            )
            if case let .arming(seconds) = controller.state {
                Label(
                    String(format: L("Keyboard Lock Countdown"), seconds),
                    systemImage: "timer"
                )
                    .foregroundStyle(.orange)
            }
            HStack {
                Label(L("Keyboard Lock Shortcut"), systemImage: "keyboard")
                Spacer()
                ShortcutRecorder(
                    shortcut: controller.shortcut,
                    prompt: L("Press Shortcut"),
                    accessibilityLabel: L("Keyboard Lock Shortcut")
                ) { shortcut in
                    _ = controller.setShortcut(shortcut)
                }
                    .frame(width: 112)
                if controller.shortcut != KeyboardLockController.defaultShortcut {
                    Button {
                        controller.resetShortcut()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.borderless)
                    .help(L("Restore Default Shortcut"))
                }
            }
            switch controller.registrationState {
            case .registered:
                Label(L("Keyboard Lock Shortcut Registered"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .conflict:
                Label(L("Keyboard Lock Shortcut Conflicts"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            case .failed:
                Label(L("Keyboard Lock Shortcut Unavailable"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            case .disabled:
                EmptyView()
            }
            if case .permissionRequired = controller.state {
                Button(L("Open Accessibility Settings")) {
                    AccessibilityPermission.openSettings()
                }
            }
            Picker(
                L("Keyboard Lock Auto Unlock"),
                selection: Binding(
                    get: { controller.autoUnlockMinutes },
                    set: { controller.setAutoUnlockMinutes($0) }
                )
            ) {
                Text(L("Never")).tag(0)
                ForEach([5, 15, 30, 60], id: \.self) { minutes in
                    Text(String(format: L("Minutes Format"), minutes)).tag(minutes)
                }
            }
            if let error = controller.lastErrorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text(L("Keyboard Lock"))
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("Keyboard Lock Help"))
                Text(L("Keyboard Lock Hardware Limitation"))
            }
        }
    }
}

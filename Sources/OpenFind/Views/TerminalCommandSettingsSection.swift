import SwiftUI

struct TerminalCommandSettingsSection: View {
    @AppStorage(QuickTerminalPrefix.persistenceKey)
    private var storedPrefix = QuickTerminalPrefix.defaultValue

    private var prefix: String {
        QuickTerminalPrefix.normalized(storedPrefix) ?? QuickTerminalPrefix.defaultValue
    }

    var body: some View {
        Section {
            Picker(L("Terminal Command Prefix"), selection: Binding(
                get: { prefix }, set: { storedPrefix = $0 }
            )) {
                ForEach(QuickTerminalPrefix.choices, id: \.self) { letter in
                    Text(letter).tag(letter)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("OpenFind.settings.terminalPrefix")

            Text(String(format: L("Terminal Command Example Format"), prefix))
                .font(.footnote)
                .foregroundStyle(.secondary)

            if prefix != QuickTerminalPrefix.defaultValue {
                Button(L("Restore Default Terminal Prefix")) {
                    storedPrefix = QuickTerminalPrefix.defaultValue
                }
            }
        } header: {
            Text(L("Run in Ghostty"))
        } footer: {
            Text(L("Terminal Command Prefix Help"))
        }
    }
}

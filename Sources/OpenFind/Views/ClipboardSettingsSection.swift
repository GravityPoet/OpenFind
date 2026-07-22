import SwiftUI

struct ClipboardSettingsSection: View {
    @Bindable var store: ClipboardHistoryStore
    @Bindable var controller: ClipboardController

    var body: some View {
        Section {
            Toggle(L("Enable Clipboard History"), isOn: persistenceBinding)

            if store.requiresPersistenceMigration {
                migrationControls
            }

            ClipboardCaptureSettings(store: store)

            DisclosureGroup(L("Clipboard Storage Settings")) {
                ClipboardStorageSettings(store: store)
                    .padding(.top, 6)
            }

            DisclosureGroup(L("Clipboard Behavior Settings")) {
                ClipboardBehaviorSettings(store: store, controller: controller)
                    .padding(.top, 6)
            }

            DisclosureGroup(L("Clipboard Appearance Settings")) {
                ClipboardAppearanceSettings(store: store)
                    .padding(.top, 6)
            }

            Button(L("Clear Clipboard History"), role: .destructive) {
                store.clearAll()
            }
            .disabled(store.entries.isEmpty)
        } header: {
            Text(L("Clipboard History"))
        } footer: {
            Text(L("Clipboard History Help"))
        }
    }

    private var migrationControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L("Clipboard Migration Required"), systemImage: "key.fill")
                .font(.headline)
            Text(L("Clipboard Migration Help"))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button(L("Unlock and Migrate Clipboard History")) {
                store.migratePersistence()
            }
        }
        .padding(.vertical, 4)
    }

    private var persistenceBinding: Binding<Bool> {
        Binding(
            get: { store.isPersistenceEnabled },
            set: { store.setPersistenceEnabled($0) }
        )
    }
}

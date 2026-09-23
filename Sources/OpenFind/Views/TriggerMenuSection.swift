import SwiftUI

struct TriggerMenuSection: View {
    @Bindable var store: TriggerStore
    @Bindable var coordinator: TriggerCoordinator

    var body: some View {
        Menu {
            if !store.triggers.isEmpty || store.isEnabled {
                Toggle(
                L("Enable Triggers"),
                isOn: Binding(
                    get: { store.isEnabled },
                    set: { enabled in
                        store.setEnabled(enabled)
                        Task { @MainActor in
                            await coordinator.evaluate(snapshot: coordinator.currentSnapshot)
                        }
                    }
                )
                )
            }
            if store.triggers.isEmpty {
                Text(L("No Triggers"))
            } else if let activeTriggerID = coordinator.activeTriggerID,
               let trigger = store.triggers.first(where: { $0.id == activeTriggerID }) {
                Label(trigger.name, systemImage: "bolt.fill")
                    .foregroundStyle(.green)
            } else {
                Text(L("No Active Trigger"))
                    .foregroundStyle(.secondary)
            }
            Divider()
            Button(L("Manage Triggers")) {
                FileActions.openSettings(pane: .triggers)
            }
        } label: {
            Label(
                coordinator.activeTriggerID == nil ? L("Triggers") : L("Triggers Running"),
                systemImage: "bolt"
            )
        }
    }
}

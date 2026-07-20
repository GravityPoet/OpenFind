import SwiftUI

struct TriggerMenuSection: View {
    @Bindable var store: TriggerStore
    @Bindable var coordinator: TriggerCoordinator

    var body: some View {
        Section(L("Triggers")) {
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
            if let activeTriggerID = coordinator.activeTriggerID,
               let trigger = store.triggers.first(where: { $0.id == activeTriggerID }) {
                Label(trigger.name, systemImage: "bolt.fill")
                    .foregroundStyle(.green)
            } else {
                Text(L("No Active Trigger"))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

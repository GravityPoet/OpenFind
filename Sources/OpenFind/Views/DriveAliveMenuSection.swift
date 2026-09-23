import SwiftUI

struct DriveAliveMenuSection: View {
    @Bindable var store: DriveAliveStore
    @Bindable var controller: DriveAliveController

    var body: some View {
        Section(L("Drive Alive")) {
            if store.targets.isEmpty {
                Text(L("No Drive Alive Targets"))
                    .foregroundStyle(.secondary)
            } else {
                Text(String(format: L("Drive Alive Status Format"), controller.activeTargetCount, store.targets.count))
                    .foregroundStyle(.secondary)
                ForEach(store.targets) { target in
                    HStack {
                        Label(target.displayName, systemImage: "externaldrive")
                            .lineLimit(1)
                        Spacer()
                        statusImage(for: target.id)
                        Button(L("Wake Disk Now")) {
                            Task { @MainActor in await controller.wake(targetID: target.id) }
                        }
                        .buttonStyle(.borderless)
                        .disabled(controller.wakingTargetIDs.contains(target.id))
                        .help(L("Wake Disk Now"))
                        .accessibilityLabel(
                            controller.wakingTargetIDs.contains(target.id)
                                ? L("Waking Disk") : L("Wake Disk Now")
                        )
                    }
                    .help(target.policy == .whileOpenFindRuns
                        ? L("While OpenFind Runs")
                        : L("During Awake Sessions"))
                }
                Button(L("Refresh Drive Alive")) {
                    Task { await controller.refresh() }
                }
            }
            DisclosureGroup(L("Advanced Continuous Mode")) {
                Toggle(
                    L("Enable Drive Alive"),
                    isOn: Binding(
                        get: { store.isEnabled },
                        set: { enabled in
                            store.setEnabled(enabled)
                            Task { @MainActor in await controller.refresh() }
                        }
                    )
                )
                Text(controller.isRunning ? L("Continuous Mode On") : L("Continuous Mode Off"))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func statusImage(for id: UUID) -> some View {
        if controller.wakingTargetIDs.contains(id) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
                .accessibilityLabel(L("Waking Disk"))
        } else {
            switch controller.statuses[id] ?? .inactive {
            case .inactive:
                Image(systemName: "pause.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(L("Drive Alive Inactive"))
            case .writing:
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(L("Drive Alive Writing"))
            case .healthy:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel(L("Drive Alive Healthy"))
            case let .failed(failure):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel(failure.localizedDescription)
            }
        }
    }
}

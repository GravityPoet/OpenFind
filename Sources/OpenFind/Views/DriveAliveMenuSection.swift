import SwiftUI

struct DriveAliveMenuSection: View {
    @Bindable var store: DriveAliveStore
    @Bindable var controller: DriveAliveController

    var body: some View {
        Section(L("Drive Alive")) {
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
                    }
                    .help(target.policy == .whileOpenFindRuns
                        ? L("While OpenFind Runs")
                        : L("During Awake Sessions"))
                }
                Button(L("Refresh Drive Alive")) {
                    Task { await controller.refresh() }
                }
            }
        }
    }

    @ViewBuilder
    private func statusImage(for id: UUID) -> some View {
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

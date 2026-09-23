import SwiftUI

struct DriveAliveMenuSection: View {
    @Bindable var store: DriveAliveStore
    @Bindable var controller: DriveAliveController

    var body: some View {
        Menu {
            if store.targets.isEmpty {
                Text(L("No Drive Alive Targets"))
                    .foregroundStyle(.secondary)
            } else {
                Label {
                    Text(String(format: L("Drive Alive Status Format"), controller.activeTargetCount, store.targets.count))
                } icon: {
                    Image(systemName: controller.activeTargetCount > 0
                        ? "externaldrive.fill.badge.checkmark"
                        : "externaldrive")
                }
                .foregroundStyle(controller.activeTargetCount > 0 ? .primary : .secondary)

                ForEach(store.targets) { target in
                    Button {
                        Task { @MainActor in await controller.wake(targetID: target.id) }
                    } label: {
                        Label {
                            Text(String(format: L("Wake Target Format"), target.displayName))
                                .lineLimit(1)
                        } icon: {
                            statusIcon(for: target.id)
                        }
                    }
                    .disabled(!controller.canWake(targetID: target.id))
                }

                Button {
                    Task { @MainActor in await controller.refreshStatus() }
                } label: {
                    Label(L("Refresh Drive Alive"), systemImage: "arrow.clockwise")
                }

                Divider()
            }

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

            Button {
                FileActions.openSettings(pane: .driveAlive)
            } label: {
                Label(L("Configure Drive Alive"), systemImage: "gearshape.2")
            }
        } label: {
            Label(L("Drive Alive"), systemImage: "externaldrive")
        }
    }

    private func statusIcon(for id: UUID) -> Image {
        if controller.wakingTargetIDs.contains(id) {
            return Image(systemName: "arrow.triangle.2.circlepath")
        }
        switch controller.statuses[id] ?? .inactive {
        case .inactive:
            return Image(systemName: "pause.circle")
        case .writing:
            return Image(systemName: "arrow.triangle.2.circlepath")
        case .healthy:
            return Image(systemName: "checkmark.circle.fill")
        case .failed:
            return Image(systemName: "exclamationmark.triangle.fill")
        }
    }
}

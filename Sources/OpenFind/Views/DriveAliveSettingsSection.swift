import SwiftUI

struct DriveAliveSettingsSection: View {
    @Bindable var store: DriveAliveStore
    @Bindable var controller: DriveAliveController
    @State private var errorMessage: String?

    var body: some View {
        Section {
            Toggle(L("Enable Drive Alive"), isOn: enabledBinding)

            HStack {
                Text(L("Write Interval"))
                Spacer()
                TextField(
                    L("Seconds"),
                    value: intervalBinding,
                    format: .number.precision(.fractionLength(0...1))
                )
                .multilineTextAlignment(.trailing)
                .frame(width: 72)
                Text(L("Seconds"))
                    .foregroundStyle(.secondary)
            }

            ForEach(store.targets) { target in
                targetRow(target)
            }

            HStack {
                Button {
                    addTargets()
                } label: {
                    Label(L("Add Drive Alive Folder"), systemImage: "plus")
                }
                .buttonStyle(.borderless)

                Spacer()

                if !store.targets.isEmpty {
                    Text(String(format: L("Drive Alive Target Count"), store.targets.count))
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                }
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.footnote)
            }
            if let controllerError = controller.lastErrorMessage {
                HStack {
                    Label(controllerError, systemImage: "exclamationmark.triangle")
                    Spacer()
                    Button {
                        controller.clearError()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                }
                .foregroundStyle(.orange)
                .font(.footnote)
            }
        } header: {
            Text(L("Drive Alive"))
        } footer: {
            Text(L("Drive Alive Help"))
        }
    }

    private func targetRow(_ target: DriveAliveTarget) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(target.displayName, systemImage: "externaldrive")
                    .lineLimit(1)
                Spacer()
                statusLabel(for: target.id)
                Button {
                    remove(target)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help(L("Remove Drive Alive Folder"))
                .accessibilityLabel(L("Remove Drive Alive Folder"))
            }

            Picker(L("Drive Alive Policy"), selection: policyBinding(for: target)) {
                Text(L("During Awake Sessions")).tag(DriveAlivePolicy.duringAwakeSession)
                Text(L("While OpenFind Runs")).tag(DriveAlivePolicy.whileOpenFindRuns)
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    private func statusLabel(for id: UUID) -> some View {
        Group {
            switch controller.statuses[id] ?? .inactive {
            case .inactive:
                Label(L("Drive Alive Inactive"), systemImage: "pause.circle")
            case .writing:
                Label(L("Drive Alive Writing"), systemImage: "arrow.triangle.2.circlepath")
            case .healthy:
                Label(L("Drive Alive Healthy"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case let .failed(failure):
                Label(failure.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private var intervalBinding: Binding<TimeInterval> {
        Binding(
            get: { store.interval },
            set: { value in
                do {
                    try store.setInterval(value)
                    errorMessage = nil
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        )
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { store.isEnabled },
            set: { enabled in
                store.setEnabled(enabled)
                Task { @MainActor in await controller.refresh() }
            }
        )
    }

    private func policyBinding(for target: DriveAliveTarget) -> Binding<DriveAlivePolicy> {
        Binding(
            get: { target.policy },
            set: { policy in
                do {
                    try store.setPolicy(policy, id: target.id)
                    errorMessage = nil
                    Task { @MainActor in await controller.refresh() }
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        )
    }

    private func addTargets() {
        for url in FileActions.chooseDirectories() {
            do {
                _ = try store.add(directoryURL: url)
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        Task { await controller.refresh() }
    }

    private func remove(_ target: DriveAliveTarget) {
        Task { @MainActor in
            do {
                try await controller.removeTarget(id: target.id)
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

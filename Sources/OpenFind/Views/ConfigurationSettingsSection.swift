import SwiftUI

struct ConfigurationSettingsSection: View {
    @Bindable var controller: ConfigurationSyncController

    var body: some View {
        Section {
            HStack {
                Button(L("Export Configuration")) { save() }
                    .accessibilityIdentifier("configuration.export")
                Button(L("Import Configuration")) { load() }
                    .accessibilityIdentifier("configuration.import")
                if controller.hasRecovery {
                    Button(L("Restore Previous Configuration")) { Task { await controller.restore() } }
                        .accessibilityIdentifier("configuration.restore")
                }
            }
            if let folder = controller.folder {
                LabeledContent(L("Sync Folder"), value: folder.path)
                    .lineLimit(1).truncationMode(.middle)
                HStack {
                    Button(L("Sync Now")) { Task { await controller.synchronize() } }
                    Button(L("Disconnect Sync")) { controller.disconnect() }
                }
            } else {
                Button(L("Choose Sync Folder")) { chooseFolder() }
                    .accessibilityIdentifier("configuration.connect")
            }
            if controller.hasConflict {
                HStack {
                    Button(L("Use This Mac Configuration")) { Task { await controller.resolveConflict(useLocal: true) } }
                    Button(L("Use Synced Configuration")) { Task { await controller.resolveConflict(useLocal: false) } }
                }
            }
            if let message = controller.message {
                Text(message).font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("configuration.status")
            }
            if controller.isBusy { ProgressView().controlSize(.small) }
        } header: {
            Text(L("Configuration and Sync"))
        } footer: {
            Text(L("Configuration Scope Help"))
        }
        .disabled(controller.isBusy)
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "OpenFind-Configuration.json"
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            Task { await controller.export(to: url) }
        }
    }

    private func load() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            let confirmation = NSAlert()
            confirmation.messageText = L("Import Configuration")
            confirmation.informativeText = L("Configuration Import Help")
            confirmation.addButton(withTitle: L("Import Configuration"))
            confirmation.addButton(withTitle: L("Cancel"))
            guard confirmation.runModal() == .alertFirstButtonReturn else { return }
            Task { await controller.importConfiguration(from: url) }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = L("Configuration Folder Help")
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            Task { await controller.connect(url) }
        }
    }
}

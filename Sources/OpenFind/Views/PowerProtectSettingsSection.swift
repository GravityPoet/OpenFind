import SwiftUI

struct PowerProtectSettingsSection: View {
    @Bindable var controller: PowerProtectController

    var body: some View {
        Section {
            switch controller.state {
            case .notInstalled:
                Label(L("Power Protect Not Installed"), systemImage: "shield")
                Button(L("Install Power Protect")) { controller.install() }
            case .installed:
                Label(L("Power Protect Installed"), systemImage: "checkmark.shield.fill")
                    .foregroundStyle(.green)
                Button(L("Uninstall Power Protect"), role: .destructive) {
                    controller.uninstall()
                }
            case .invalid:
                Label(L("Power Protect Rule Invalid"), systemImage: "exclamationmark.shield.fill")
                    .foregroundStyle(.orange)
            case .unsupported:
                Label(L("Power Protect Unsupported"), systemImage: "nosign")
                    .foregroundStyle(.secondary)
            case .working:
                HStack {
                    ProgressView().controlSize(.small)
                    Text(L("Updating Power Protect"))
                }
            }

            Text("/usr/bin/pmset -a disablesleep 1\n/usr/bin/pmset -a disablesleep 0")
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)

            if let error = controller.lastErrorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Button(L("Dismiss Error")) { controller.clearError() }
            }
        } header: {
            Text(L("Power Protect"))
        } footer: {
            Text(L("Power Protect Help"))
        }
        .onAppear { controller.refresh() }
    }
}

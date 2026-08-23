import SwiftUI

struct KeyboardLockMenuSection: View {
    @Bindable var controller: KeyboardLockController

    var body: some View {
        Section(L("Keyboard Cleaning")) {
            Button {
                controller.toggle()
            } label: {
                Label(
                    controller.isEngaged
                        ? L("Unlock Keyboard")
                        : L("Lock Keyboard"),
                    systemImage: controller.isEngaged
                        ? "keyboard.fill"
                        : "keyboard"
                )
            }

            if let error = controller.lastErrorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)

                if case .permissionRequired = controller.state {
                    Button(L("Open Accessibility Settings")) {
                        AccessibilityPermission.openSettings()
                    }
                }

                Button(L("Dismiss Error")) {
                    controller.clearError()
                }
            }
        }
    }
}

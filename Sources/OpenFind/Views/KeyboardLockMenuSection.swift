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
        }
    }
}

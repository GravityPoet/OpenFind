import SwiftUI

struct OpenFindApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(
                viewModel: appDelegate.viewModel,
                globalHotKey: appDelegate.globalHotKey
            )
        }
        .commands {
            AppCommands(viewModel: appDelegate.viewModel)
        }
    }
}

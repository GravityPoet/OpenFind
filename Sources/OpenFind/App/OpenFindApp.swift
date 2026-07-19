import AppKit
import SwiftUI

struct OpenFindApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            Button(L("Show OpenFind")) {
                appDelegate.showOpenFindWindow(nil)
            }

            Button(L("Settings")) {
                appDelegate.showSettingsWindow(nil)
            }

            Divider()

            Button(L("Quit OpenFind")) {
                NSApp.terminate(nil)
            }
        } label: {
            Image(nsImage: MenuBarIcon.make())
                .accessibilityLabel("OpenFind")
        }
        .menuBarExtraStyle(.menu)

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

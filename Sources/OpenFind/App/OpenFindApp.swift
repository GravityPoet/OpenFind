import AppKit
import MenuBarExtraAccess
import SwiftUI

struct OpenFindApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var isMenuPresented = false

    var body: some Scene {
        MenuBarExtra {
            Button(L("Show OpenFind")) {
                appDelegate.showOpenFindWindow(nil)
            }

            AwakeMenuSection(
                controller: appDelegate.awakeSession,
                preferences: appDelegate.awakeSessionPreferences
            )
            TriggerMenuSection(
                store: appDelegate.triggerStore,
                coordinator: appDelegate.triggerCoordinator
            )
            DriveAliveMenuSection(
                store: appDelegate.driveAliveStore,
                controller: appDelegate.driveAlive
            )

            Divider()

            ClipboardMenuSection(
                store: appDelegate.clipboardStore,
                controller: appDelegate.clipboard
            )

            Button {
                appDelegate.keyboardLock.toggle()
            } label: {
                Label(
                    appDelegate.keyboardLock.isEngaged
                        ? L("Unlock Keyboard")
                        : L("Lock Keyboard"),
                    systemImage: appDelegate.keyboardLock.isEngaged
                        ? "keyboard.fill"
                        : "keyboard"
                )
            }

            Divider()

            OpenFindSettingsMenuItem()

            Button(L("Quit OpenFind")) {
                NSApp.terminate(nil)
            }
        } label: {
            OpenFindMenuBarLabel(
                controller: appDelegate.awakeSession,
                preferences: appDelegate.awakeSessionPreferences
            )
        }
        .menuBarExtraAccess(isPresented: $isMenuPresented) { statusItem in
            appDelegate.menuBarPresentation.attach(statusItem) { action in
                switch action {
                case .toggleCapture:
                    appDelegate.clipboardStore.setCapturePaused(
                        !appDelegate.clipboardStore.preferences.capturePaused
                    )
                case .ignoreNextCapture:
                    appDelegate.clipboardStore.ignoreNextCapture()
                }
            }
        }
        .menuBarExtraStyle(.menu)
        .commands {
            AppCommands(
                viewModel: appDelegate.viewModel,
                clipboardStore: appDelegate.clipboardStore
            )
        }
    }
}

private struct OpenFindSettingsMenuItem: View {
    var body: some View {
        Button(L("Settings")) {
            FileActions.openSettings()
        }
    }
}

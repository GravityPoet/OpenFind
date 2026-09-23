import AppKit
import MenuBarExtraAccess
import SwiftUI

struct OpenFindApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var isMenuPresented = false

    var body: some Scene {
        MenuBarExtra {
            Button {
                appDelegate.showQuickSearch(nil)
            } label: {
                Label(L("Quick Search"), systemImage: "magnifyingglass")
            }

            Button {
                appDelegate.showOpenFindWindow(nil)
            } label: {
                Label(L("Full Search"), systemImage: "doc.text.magnifyingglass")
            }

            Divider()

            ClipboardMenuSection(
                store: appDelegate.clipboardStore,
                controller: appDelegate.clipboard
            )
            KeyboardLockMenuSection(controller: appDelegate.keyboardLock)

            Divider()

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

            OpenFindSettingsMenuItem()

            Button(L("Quit OpenFind")) {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
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

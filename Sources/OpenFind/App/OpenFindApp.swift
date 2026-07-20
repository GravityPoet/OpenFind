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

            Button {
                appDelegate.clipboard.showWindow()
            } label: {
                Label(L("Clipboard History"), systemImage: "doc.on.clipboard")
            }
            if case .conflict = appDelegate.clipboard.registrationState {
                Text(L("Clipboard Shortcut Conflicts"))
                    .foregroundStyle(.orange)
            }

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

            SettingsLink {
                Text(L("Settings"))
            }

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
            appDelegate.menuBarPresentation.attach(statusItem)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(
                viewModel: appDelegate.viewModel,
                globalHotKey: appDelegate.globalHotKey,
                driveAliveStore: appDelegate.driveAliveStore,
                driveAlive: appDelegate.driveAlive,
                clipboardStore: appDelegate.clipboardStore,
                clipboard: appDelegate.clipboard,
                keyboardLock: appDelegate.keyboardLock,
                triggerStore: appDelegate.triggerStore,
                triggerCoordinator: appDelegate.triggerCoordinator,
                awakeHotKeys: appDelegate.awakeHotKeys,
                awakeSessionPreferences: appDelegate.awakeSessionPreferences,
                launchAtLogin: appDelegate.launchAtLogin,
                awakeNotifications: appDelegate.awakeNotifications,
                awakeStatistics: appDelegate.awakeStatistics,
                sessionActivity: appDelegate.sessionActivity,
                powerProtect: appDelegate.powerProtect,
                awakeSession: appDelegate.awakeSession
            )
        }
        .commands {
            AppCommands(viewModel: appDelegate.viewModel)
        }
    }
}

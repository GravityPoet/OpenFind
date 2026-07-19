import AppKit
import Sparkle
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let viewModel = SearchViewModel()
    let globalHotKey = GlobalHotKeyController()
    let quickLook = QuickLookController()
    private let mainWindowFrameAutosaveName = NSWindow.FrameAutosaveName("OpenFind.mainWindow")
    private let settingsWindowFrameAutosaveName = NSWindow.FrameAutosaveName("OpenFind.settingsWindow")
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var updaterController: SPUStandardUpdaterController?
    private var terminationReplyPending = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureUpdaterIfAvailable()
        showMainWindow()
        globalHotKey.start { [weak self] in
            self?.toggleMainWindow()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        globalHotKey.stop()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationReplyPending else { return .terminateLater }
        terminationReplyPending = true
        globalHotKey.stop()
        viewModel.cancel()
        Task { [weak self, weak sender] in
            await self?.viewModel.flushIndexPersistence()
            sender?.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @objc func showOpenFindWindow(_ sender: Any?) {
        showMainWindow()
    }

    @objc func showSettingsWindow(_ sender: Any?) {
        let window = makeSettingsWindowIfNeeded()
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc func checkForUpdates(_ sender: Any?) {
        updaterController?.checkForUpdates(sender)
    }

    var canCheckForUpdates: Bool {
        updaterController?.updater.canCheckForUpdates == true
    }

    private func configureUpdaterIfAvailable() {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let feed = info["SUFeedURL"] as? String,
              let feedURL = URL(string: feed),
              feedURL.scheme?.lowercased() == "https",
              let publicKey = info["SUPublicEDKey"] as? String,
              !publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    private func toggleMainWindow() {
        let window = makeMainWindowIfNeeded()

        if window.isVisible && NSApp.isActive {
            quickLook.close()
            NSApp.hide(nil)
            return
        }

        showMainWindow(window)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === mainWindow else { return true }
        quickLook.close()
        NSApp.hide(nil)
        return false
    }

    func windowDidMove(_ notification: Notification) {
        saveFrameIfNeeded(notification.object as? NSWindow)
    }

    func windowDidResize(_ notification: Notification) {
        saveFrameIfNeeded(notification.object as? NSWindow)
    }

    private var availableMainWindow: NSWindow? {
        mainWindow ?? NSApp.windows.first { window in
            window.identifier?.rawValue == "OpenFind.main"
        }
    }

    private var availableSettingsWindow: NSWindow? {
        settingsWindow ?? NSApp.windows.first { window in
            window.identifier?.rawValue == "OpenFind.settings"
        }
    }

    private func showMainWindow(_ window: NSWindow? = nil) {
        let window = window ?? makeMainWindowIfNeeded()

        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .openFindFocusSearch, object: nil)
    }

    private func makeMainWindowIfNeeded() -> NSWindow {
        if let window = availableMainWindow {
            if window.isMiniaturized { window.deminiaturize(nil) }
            return window
        }

        let hostingController = NSHostingController(
            rootView: ContentView(viewModel: viewModel, quickLook: quickLook)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("OpenFind.main")
        window.title = "OpenFind"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 800, height: 500)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = hostingController
        applySavedFrameOrCenter(window, autosaveName: mainWindowFrameAutosaveName)
        mainWindow = window
        return window
    }

    private func makeSettingsWindowIfNeeded() -> NSWindow {
        if let window = availableSettingsWindow {
            if window.isMiniaturized { window.deminiaturize(nil) }
            return window
        }

        let hostingController = NSHostingController(
            rootView: SettingsView(viewModel: viewModel, globalHotKey: globalHotKey)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("OpenFind.settings")
        window.title = L("Settings")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = hostingController
        applySavedFrameOrCenter(window, autosaveName: settingsWindowFrameAutosaveName)
        settingsWindow = window
        return window
    }

    private func applySavedFrameOrCenter(_ window: NSWindow, autosaveName: NSWindow.FrameAutosaveName) {
        let restored = window.setFrameUsingName(autosaveName)
        window.setFrameAutosaveName(autosaveName)

        if restored {
            ensureWindowFrameIsVisible(window)
        } else {
            window.center()
        }
    }

    private func saveFrameIfNeeded(_ window: NSWindow?) {
        guard let window else { return }
        if window === mainWindow {
            window.saveFrame(usingName: mainWindowFrameAutosaveName)
        } else if window === settingsWindow {
            window.saveFrame(usingName: settingsWindowFrameAutosaveName)
        }
    }

    private func ensureWindowFrameIsVisible(_ window: NSWindow) {
        guard let visibleFrame = visibleFrame(for: window.frame) else {
            window.center()
            return
        }

        let frame = clampedFrame(window.frame, to: visibleFrame, minimumSize: window.minSize)
        if frame != window.frame {
            window.setFrame(frame, display: false)
        }
    }

    private func visibleFrame(for frame: NSRect) -> NSRect? {
        if let matchingScreen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(frame) }) {
            return matchingScreen.visibleFrame
        }
        return NSScreen.main?.visibleFrame
    }

    private func clampedFrame(_ frame: NSRect, to visibleFrame: NSRect, minimumSize: NSSize) -> NSRect {
        var size = frame.size
        let minimumWidth = min(max(minimumSize.width, 1), visibleFrame.width)
        let minimumHeight = min(max(minimumSize.height, 1), visibleFrame.height)
        size.width = min(max(size.width, minimumWidth), visibleFrame.width)
        size.height = min(max(size.height, minimumHeight), visibleFrame.height)

        var origin = frame.origin
        origin.x = min(max(origin.x, visibleFrame.minX), visibleFrame.maxX - size.width)
        origin.y = min(max(origin.y, visibleFrame.minY), visibleFrame.maxY - size.height)

        return NSRect(origin: origin, size: size)
    }
}

extension Notification.Name {
    static let openFindFocusSearch = Notification.Name("OpenFind.focusSearch")
}

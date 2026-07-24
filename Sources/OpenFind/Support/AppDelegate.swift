import AppKit
import OSLog
import Sparkle
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    /// SwiftUI's `NSApplicationDelegateAdaptor` may expose a forwarding
    /// delegate while Cocoa scripting is dispatching an `NSScriptCommand`.
    /// Keep a weak, process-local reference so scripting can still resolve
    /// the live application services without extending the delegate lifetime.
    private(set) static weak var shared: AppDelegate?

    private let lifecycleLogger = Logger(subsystem: "com.openfind.app", category: "Lifecycle")
    let viewModel = SearchViewModel()
    let hotKeyRegistry: GlobalHotKeyRegistry
    let globalHotKey: GlobalHotKeyController
    let clipboardStore: ClipboardHistoryStore
    let clipboard: ClipboardController
    let keyboardLock: KeyboardLockController
    let awakeSession: AwakeSessionController
    let awakeSessionPreferences: AwakeSessionPreferences
    let awakeAutomation: AwakeAutomationController
    let awakeNotifications: AwakeNotificationController
    let awakeStatistics: AwakeStatisticsController
    let sessionActivity: SessionActivityController
    let powerProtect: PowerProtectController
    let launchAtLogin: LaunchAtLoginController
    let menuBarPresentation: MenuBarPresentationController
    let awakeHotKeys: AwakeHotKeyController
    let triggerStore: TriggerStore
    let driveAliveStore: DriveAliveStore
    let driveAlive: DriveAliveController
    let triggerCoordinator: TriggerCoordinator
    let triggerScheduler: TriggerMonitorScheduler
    let quickLook = QuickLookController()
    private let mainWindowFrameAutosaveName = NSWindow.FrameAutosaveName("OpenFind.mainWindow")
    private let settingsWindowFrameAutosaveName =
        NSWindow.FrameAutosaveName("OpenFind.settingsWindow")
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var updaterController: SPUStandardUpdaterController?
    private var terminationReplyPending = false
    private var closedDisplayRecoveryTask: Task<Void, Never>?
    private var backgroundHibernateTask: Task<Void, Never>?
    private var isBackgroundResident = false
    var activationPolicySetter: (NSApplication.ActivationPolicy) -> Bool = {
        NSApp.setActivationPolicy($0)
    }

    override init() {
        let hotKeyRegistry = GlobalHotKeyRegistry()
        self.hotKeyRegistry = hotKeyRegistry
        self.globalHotKey = GlobalHotKeyController(registry: hotKeyRegistry)
        let clipboardStore = ClipboardHistoryStore()
        self.clipboardStore = clipboardStore
        self.clipboard = ClipboardController(registry: hotKeyRegistry, store: clipboardStore)
        self.keyboardLock = KeyboardLockController(registry: hotKeyRegistry)
        let awakeSession = AwakeSessionController()
        let awakeSessionPreferences = AwakeSessionPreferences()
        let triggerStore = TriggerStore()
        let driveAliveStore = DriveAliveStore()
        self.awakeSession = awakeSession
        self.awakeSessionPreferences = awakeSessionPreferences
        self.awakeAutomation = AwakeAutomationController(
            sessions: awakeSession,
            preferences: awakeSessionPreferences
        )
        self.awakeNotifications = AwakeNotificationController(sessions: awakeSession)
        self.awakeStatistics = AwakeStatisticsController(sessions: awakeSession)
        self.sessionActivity = SessionActivityController(
            sessions: awakeSession,
            preferences: awakeSessionPreferences
        )
        self.powerProtect = PowerProtectController()
        self.launchAtLogin = LaunchAtLoginController()
        let menuBarPresentation = MenuBarPresentationController()
        self.menuBarPresentation = menuBarPresentation
        self.awakeHotKeys = AwakeHotKeyController(
            registry: hotKeyRegistry,
            sessions: awakeSession,
            preferences: awakeSessionPreferences,
            openMenu: {
                _ = menuBarPresentation.present()
            }
        )
        self.triggerStore = triggerStore
        self.driveAliveStore = driveAliveStore
        self.driveAlive = DriveAliveController(store: driveAliveStore, sessions: awakeSession)
        triggerCoordinator = TriggerCoordinator(store: triggerStore, sessions: awakeSession)
        triggerScheduler = TriggerMonitorScheduler(coordinator: triggerCoordinator)
        super.init()
        Self.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        launchAtLogin.enableByDefaultIfNeeded()
        configureUpdaterIfAvailable()
        if Self.isLoginItemLaunch(
            event: NSAppleEventManager.shared().currentAppleEvent
        ) {
            enterBackgroundMode()
        } else {
            showMainWindow()
        }
        startRuntimeServices(includeTriggerScheduler: false)
        closedDisplayRecoveryTask = Task { [weak self] in
            guard let self else { return }
            let recovered = await self.awakeSession.recoverClosedDisplayState()
            guard !Task.isCancelled else {
                self.closedDisplayRecoveryTask = nil
                return
            }
            if !recovered {
                // A stale privileged journal must not strand unrelated
                // Trigger evaluation and Drive Alive. Closed-display
                // sessions remain gated by the controller's pending journal;
                // ordinary criteria can still be evaluated and surfaced to
                // the user while recovery is repaired.
                self.lifecycleLogger.error(
                    "Closed-display recovery failed; continuing non-privileged runtime services"
                )
            }
            self.triggerScheduler.start()
            if recovered {
                self.awakeAutomation.handleApplicationLaunch()
            }
            self.closedDisplayRecoveryTask = nil
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        backgroundHibernateTask?.cancel()
        backgroundHibernateTask = nil
        clipboardStore.prepareForTermination()
        stopRuntimeServices()
        if Self.shared === self { Self.shared = nil }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationReplyPending else {
            lifecycleLogger.notice("Termination request is already pending")
            return .terminateLater
        }
        lifecycleLogger.notice("Termination cleanup started")
        terminationReplyPending = true
        backgroundHibernateTask?.cancel()
        backgroundHibernateTask = nil
        stopRuntimeServices()
        Task { @MainActor [weak self, weak sender] in
            guard let self else {
                Logger(subsystem: "com.openfind.app", category: "Lifecycle")
                    .error("Termination delegate disappeared before cleanup")
                sender?.reply(toApplicationShouldTerminate: false)
                return
            }
            await self.viewModel.prepareForTermination()
            guard await self.awakeSession.requestEndAsync(reason: .applicationTermination) else {
                self.lifecycleLogger.error("Termination awake-session cleanup failed")
                self.terminationReplyPending = false
                self.startRuntimeServices(includeTriggerScheduler: true)
                sender?.reply(toApplicationShouldTerminate: false)
                return
            }
            self.lifecycleLogger.notice("Termination awake-session cleanup completed")
            let persistenceCompleted = await self.viewModel.flushIndexPersistence()
            self.lifecycleLogger.notice(
                "Termination index flush completed before deadline: \(persistenceCompleted, privacy: .public)"
            )
            sender?.reply(toApplicationShouldTerminate: true)
            self.lifecycleLogger.notice("Termination approval replied")
        }
        return .terminateLater
    }

    private func startRuntimeServices(includeTriggerScheduler: Bool) {
        driveAlive.start()
        clipboard.start()
        keyboardLock.start()
        awakeAutomation.start()
        awakeNotifications.start()
        sessionActivity.start()
        awakeHotKeys.start()
        globalHotKey.start { [weak self] in
            self?.toggleMainWindow()
        }
        if includeTriggerScheduler {
            triggerScheduler.start()
        }
    }

    private func stopRuntimeServices() {
        closedDisplayRecoveryTask?.cancel()
        closedDisplayRecoveryTask = nil
        triggerScheduler.stop()
        driveAlive.stop()
        clipboard.stop()
        keyboardLock.stop()
        awakeAutomation.stop()
        awakeNotifications.stop()
        sessionActivity.stop()
        awakeHotKeys.stop()
        globalHotKey.stop()
        hotKeyRegistry.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    static func isLoginItemLaunch(event: NSAppleEventDescriptor?) -> Bool {
        event?.paramDescriptor(forKeyword: keyAELaunchedAsLogInItem) != nil
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        hotKeyRegistry.retryFailedRegistrations()
    }

    func applicationDidResignActive(_ notification: Notification) {
        guard !hasVisiblePrimaryWindow else { return }
        enterBackgroundMode()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @objc func showOpenFindWindow(_ sender: Any?) {
        showMainWindow()
    }

    @objc func showSettingsWindow(_ sender: Any?) {
        let window = makeSettingsWindowIfNeeded()
        enterForegroundMode()
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(sender)
    }

    @objc func showWelcomeGuide(_ sender: Any?) {
        showMainWindow()
        Task { @MainActor in
            await Task.yield()
            NotificationCenter.default.post(name: .openFindShowWelcome, object: nil)
        }
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
            window.orderOut(nil)
            if !hasVisiblePrimaryWindow {
                enterBackgroundMode()
            }
            return
        }

        showMainWindow(window)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === mainWindow || sender === settingsWindow else { return true }
        if sender === mainWindow { quickLook.close() }
        sender.orderOut(nil)
        if !hasVisiblePrimaryWindow {
            enterBackgroundMode()
        }
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

    private func showMainWindow(_ window: NSWindow? = nil) {
        let window = window ?? makeMainWindowIfNeeded()

        enterForegroundMode()
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .openFindFocusSearch, object: nil)
    }

    private var hasVisiblePrimaryWindow: Bool {
        [mainWindow, settingsWindow].compactMap { $0 }.contains { $0.isVisible }
    }

    private func enterForegroundMode() {
        let wasBackgroundResident = isBackgroundResident
        isBackgroundResident = false
        applyActivationPolicy(.regular)
        backgroundHibernateTask?.cancel()
        backgroundHibernateTask = nil
        if wasBackgroundResident {
            viewModel.resumeFromBackground()
        }
    }

    private func enterBackgroundMode() {
        guard !hasVisiblePrimaryWindow else { return }
        guard !isBackgroundResident else { return }
        isBackgroundResident = true
        applyActivationPolicy(.accessory)
        clipboard.prepareWindowForBackgroundResidence()
        backgroundHibernateTask?.cancel()
        backgroundHibernateTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            guard let self, self.isBackgroundResident, !Task.isCancelled else { return }
            await self.viewModel.hibernateForBackground()
            guard !Task.isCancelled else { return }
            self.backgroundHibernateTask = nil
            ProcessMemoryReclaimer.schedule()
        }
    }

    private func applyActivationPolicy(_ policy: NSApplication.ActivationPolicy) {
        guard activationPolicySetter(policy) else {
            lifecycleLogger.error(
                "Failed to apply activation policy \(policy.rawValue, privacy: .public)"
            )
            return
        }
    }

    @objc private func workspaceDidWake(_ notification: Notification) {
        hotKeyRegistry.retryFailedRegistrations()
    }

    private func makeMainWindowIfNeeded() -> NSWindow {
        if let window = availableMainWindow {
            if window.isMiniaturized { window.deminiaturize(nil) }
            return window
        }

        let hostingController = NSHostingController(
            rootView: ContentView(
                viewModel: viewModel,
                quickLook: quickLook,
                onShowClipboardHistory: { [weak self] in
                    self?.clipboard.showWindow()
                },
                onShowMenuBar: { [weak self] in
                    _ = self?.menuBarPresentation.present()
                },
                onShowSettings: { [weak self] in
                    self?.showSettingsWindow(nil)
                },
                firstRunCapabilities: { [weak self] in
                    self?.makeFirstRunCapabilities() ?? []
                }
            )
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

    private func makeFirstRunCapabilities() -> [FirstRunCapability] {
        [
            FirstRunCapability(
                id: .search,
                systemImage: "magnifyingglass",
                title: L("Guide Search Title"),
                detail: L("Guide Search Detail"),
                shortcut: globalHotKey.shortcut.displayText
            ),
            FirstRunCapability(
                id: .clipboard,
                systemImage: "doc.on.clipboard",
                title: L("Guide Clipboard Title"),
                detail: L("Guide Clipboard Detail"),
                shortcut: clipboard.shortcut.displayText
            ),
            FirstRunCapability(
                id: .keepAwake,
                systemImage: "moon.zzz",
                title: L("Guide Keep Awake Title"),
                detail: L("Guide Keep Awake Detail"),
                shortcut: AwakeHotKeyAction.toggleSession.defaultShortcut.displayText
            ),
            FirstRunCapability(
                id: .driveAlive,
                systemImage: "externaldrive",
                title: L("Guide Drive Alive Title"),
                detail: L("Guide Drive Alive Detail"),
                shortcut: L("Menu Bar")
            ),
            FirstRunCapability(
                id: .keyboardCleaning,
                systemImage: "keyboard",
                title: L("Guide Keyboard Cleaning Title"),
                detail: L("Guide Keyboard Cleaning Detail"),
                shortcut: keyboardLock.shortcut.displayText
            ),
        ]
    }

    private func makeSettingsWindowIfNeeded() -> NSWindow {
        if let settingsWindow {
            if settingsWindow.isMiniaturized { settingsWindow.deminiaturize(nil) }
            return settingsWindow
        }

        let hostingController = NSHostingController(
            rootView: SettingsView(
                viewModel: viewModel,
                globalHotKey: globalHotKey,
                driveAliveStore: driveAliveStore,
                driveAlive: driveAlive,
                clipboardStore: clipboardStore,
                clipboard: clipboard,
                keyboardLock: keyboardLock,
                triggerStore: triggerStore,
                triggerCoordinator: triggerCoordinator,
                awakeHotKeys: awakeHotKeys,
                awakeSessionPreferences: awakeSessionPreferences,
                launchAtLogin: launchAtLogin,
                awakeNotifications: awakeNotifications,
                awakeStatistics: awakeStatistics,
                sessionActivity: sessionActivity,
                powerProtect: powerProtect,
                awakeSession: awakeSession
            )
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("OpenFind.settings")
        window.title = L("Settings")
        window.minSize = NSSize(width: 900, height: 620)
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
    static let openFindShowWelcome = Notification.Name("OpenFind.showWelcome")
}

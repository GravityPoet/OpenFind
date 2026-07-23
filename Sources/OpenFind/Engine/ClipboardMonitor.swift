import AppKit
import Foundation

struct ClipboardSourceApplication: Equatable, Sendable {
    let bundleIdentifier: String?
    let localizedName: String?
    let identifiers: Set<String>

    init(
        bundleIdentifier: String?,
        localizedName: String?,
        identifiers: Set<String>
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.localizedName = localizedName
        self.identifiers = identifiers
    }

    init(_ application: NSRunningApplication?) {
        bundleIdentifier = application?.bundleIdentifier
        localizedName = application?.localizedName
        identifiers = Set([
            application?.localizedName,
            application?.executableURL?.lastPathComponent,
            application?.bundleURL?.deletingPathExtension().lastPathComponent,
        ].compactMap { $0 })
    }
}

@MainActor
final class ClipboardMonitor: NSObject {
    private let store: ClipboardHistoryStore
    private let pasteboard: NSPasteboard
    private let workspace: NSWorkspace
    private let activationNotificationCenter: NotificationCenter
    private let sourceApplicationProvider: @MainActor () -> ClipboardSourceApplication?
    private let onExternalChange: @MainActor () -> Void
    private var timer: Timer?
    private var isObservingApplicationActivations = false
    private var activeApplication: ClipboardSourceApplication?
    private var lastChangeCount: Int = 0
    private var nextRetentionCleanupAt = Date.distantFuture

    init(
        store: ClipboardHistoryStore,
        pasteboard: NSPasteboard = .general,
        workspace: NSWorkspace = .shared,
        activationNotificationCenter: NotificationCenter? = nil,
        sourceApplicationProvider: (@MainActor () -> ClipboardSourceApplication?)? = nil,
        onExternalChange: @escaping @MainActor () -> Void = {}
    ) {
        self.store = store
        self.pasteboard = pasteboard
        self.workspace = workspace
        self.activationNotificationCenter =
            activationNotificationCenter ?? workspace.notificationCenter
        self.sourceApplicationProvider = sourceApplicationProvider ?? {
            ClipboardSourceApplication(workspace.frontmostApplication)
        }
        self.onExternalChange = onExternalChange
        super.init()
    }

    func start(interval: TimeInterval = 0.5) {
        stop()
        lastChangeCount = pasteboard.changeCount
        activeApplication = sourceApplicationProvider()
        nextRetentionCleanupAt = Date().addingTimeInterval(60)
        activationNotificationCenter.addObserver(
            self,
            selector: #selector(applicationDidActivateNotification(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil,
        )
        isObservingApplicationActivations = true
        let boundedInterval = min(5, max(0.1, interval))
        timer = Timer.scheduledTimer(withTimeInterval: boundedInterval, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if isObservingApplicationActivations {
            activationNotificationCenter.removeObserver(
                self,
                name: NSWorkspace.didActivateApplicationNotification,
                object: nil
            )
            isObservingApplicationActivations = false
        }
        activeApplication = nil
    }

    func poll() {
        let now = Date()
        if now >= nextRetentionCleanupAt {
            _ = store.pruneExpiredHistory(referenceDate: now)
            nextRetentionCleanupAt = now.addingTimeInterval(60)
        }
        capturePendingChange(
            source: activeApplication ?? sourceApplicationProvider()
        )
        activeApplication = sourceApplicationProvider()
    }

    func applicationDidActivate(_ application: ClipboardSourceApplication?) {
        capturePendingChange(
            source: activeApplication ?? sourceApplicationProvider()
        )
        activeApplication = application
    }

    @objc private func applicationDidActivateNotification(_ notification: Notification) {
        guard let application = notification.userInfo?[
            NSWorkspace.applicationUserInfoKey
        ] as? NSRunningApplication else { return }
        applicationDidActivate(ClipboardSourceApplication(application))
    }

    private func capturePendingChange(source: ClipboardSourceApplication?) {
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount
        let types = Set(pasteboard.pasteboardItems?.flatMap {
            $0.types.map(\.rawValue)
        } ?? [])
        if !types.contains(ClipboardHistoryStore.internalPasteboardType) {
            onExternalChange()
        }
        _ = store.captureCurrentPasteboard(
            sourceBundleIdentifier: source?.bundleIdentifier,
            sourceApplicationName: source?.localizedName,
            sourceIdentifiers: source?.identifiers ?? []
        )
    }
}

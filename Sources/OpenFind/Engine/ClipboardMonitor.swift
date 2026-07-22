import AppKit
import Foundation

@MainActor
final class ClipboardMonitor {
    private let store: ClipboardHistoryStore
    private let pasteboard: NSPasteboard
    private let workspace: NSWorkspace
    private let onExternalChange: @MainActor () -> Void
    private var timer: Timer?
    private var lastChangeCount: Int = 0

    init(
        store: ClipboardHistoryStore,
        pasteboard: NSPasteboard = .general,
        workspace: NSWorkspace = .shared,
        onExternalChange: @escaping @MainActor () -> Void = {}
    ) {
        self.store = store
        self.pasteboard = pasteboard
        self.workspace = workspace
        self.onExternalChange = onExternalChange
    }

    func start(interval: TimeInterval = 0.5) {
        stop()
        lastChangeCount = pasteboard.changeCount
        let boundedInterval = min(5, max(0.1, interval))
        timer = Timer.scheduledTimer(withTimeInterval: boundedInterval, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func poll() {
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount
        let types = Set(pasteboard.pasteboardItems?.flatMap {
            $0.types.map(\.rawValue)
        } ?? [])
        if !types.contains(ClipboardHistoryStore.internalPasteboardType) {
            onExternalChange()
        }
        let application = workspace.frontmostApplication
        _ = store.captureCurrentPasteboard(
            sourceBundleIdentifier: application?.bundleIdentifier,
            sourceApplicationName: application?.localizedName,
            sourceIdentifiers: Set([
                application?.localizedName,
                application?.executableURL?.lastPathComponent,
                application?.bundleURL?.deletingPathExtension().lastPathComponent,
            ].compactMap { $0 })
        )
    }
}

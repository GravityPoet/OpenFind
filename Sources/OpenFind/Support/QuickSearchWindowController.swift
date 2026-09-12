import AppKit
import SwiftUI

@MainActor
final class QuickSearchWindowController: NSObject, NSWindowDelegate {
    let viewModel: QuickSearchViewModel
    private let onShowFullSearch: (String) -> Void
    private let onDismiss: () -> Void
    private(set) var panel: QuickSearchPanel?
    private weak var searchField: NSTextField?
    private var hostingView: NSHostingView<QuickSearchView>?
    private var scale: CGFloat = 1
    private var launchTask: Task<Void, Never>?

    init(
        viewModel: QuickSearchViewModel = QuickSearchViewModel(),
        onShowFullSearch: @escaping (String) -> Void,
        onDismiss: @escaping () -> Void = {}
    ) {
        self.viewModel = viewModel
        self.onShowFullSearch = onShowFullSearch
        self.onDismiss = onDismiss
        super.init()
    }

    var isVisible: Bool { panel?.isVisible == true }

    func show() {
        viewModel.prepareForPresentation()
        scale = OpenFindInterfaceSize.resolve(
            UserDefaults.standard.string(forKey: OpenFindInterfaceSize.persistenceKey) ?? ""
        ).scale
        let panel = makePanelIfNeeded()
        hostingView?.rootView = makeView()
        resize(to: viewModel.presentationHeight * scale)
        position(panel)
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        panel.makeKeyAndOrderFront(nil)
        panel.contentView?.layoutSubtreeIfNeeded()
        focusSearch()
        // MenuBarExtra finishes dismissing after its action returns.
        DispatchQueue.main.async { [weak self] in self?.focusSearch() }
        Task { await ApplicationSearchIndex.shared.prewarm() }
        Task { _ = await SystemSettingsSearchIndex.shared.results(for: "") }
    }

    func close() {
        guard isVisible else { return }
        viewModel.cancel()
        panel?.orderOut(nil)
        onDismiss()
    }

    private func focusSearch() {
        guard let panel, panel.isVisible, let searchField else { return }
        panel.makeKey()
        panel.makeFirstResponder(searchField)
    }

    private func makeView() -> QuickSearchView {
        QuickSearchView(
            viewModel: viewModel, scale: scale,
            onOpen: { [weak self] in self?.open($0) },
            onFullSearch: { [weak self] in self?.showFullSearch() },
            onResize: { [weak self] in self?.resize(to: $0) },
            onInputReady: { [weak self] in self?.searchField = $0 }
        )
    }

    private func makePanelIfNeeded() -> QuickSearchPanel {
        if let panel { return panel }
        let panel = QuickSearchPanel(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 118),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.identifier = .init("OpenFind.quickSearch")
        panel.title = L("Quick Search")
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.transient, .moveToActiveSpace, .fullScreenAuxiliary]
        panel.delegate = self
        panel.onClose = { [weak self] in self?.close() }
        panel.onOpen = { [weak self] in
            guard let self, let result = viewModel.selectedResult else { return }
            open(result)
        }
        panel.onReveal = { [weak self] in
            guard let self, let result = viewModel.selectedResult else { return }
            guard result.url.isFileURL else { open(result); return }
            close()
            FileActions.revealInFinder([result.url])
        }
        panel.onFullSearch = { [weak self] in self?.showFullSearch() }
        panel.onMoveSelection = { [weak self] in self?.viewModel.moveSelection(by: $0) }
        panel.onOpenNumber = { [weak self] index in
            guard let self, viewModel.resultsAreCurrent, viewModel.results.indices.contains(index) else { return }
            open(viewModel.results[index])
        }
        self.panel = panel
        let host = NSHostingView(rootView: makeView())
        host.sizingOptions = []
        panel.contentView = host
        hostingView = host
        return panel
    }

    private func open(_ result: QuickSearchItem) {
        guard launchTask == nil, viewModel.resultsAreCurrent else { return }
        viewModel.errorMessage = nil
        launchTask = Task { [weak self] in
            guard let self else { return }
            defer { launchTask = nil }
            do {
                if result.isApplication {
                    let config = NSWorkspace.OpenConfiguration()
                    config.activates = true
                    config.createsNewApplicationInstance = false
                    _ = try await NSWorkspace.shared.openApplication(at: result.url, configuration: config)
                } else if !NSWorkspace.shared.open(result.url) {
                    throw CocoaError(.fileReadUnknown)
                }
                if result.url.isFileURL { SearchUsageStore.shared.recordSuccessfulOpen(result.url) }
                close()
            } catch {
                viewModel.errorMessage = L("Quick Search Open Failed")
                if !isVisible {
                    panel?.makeKeyAndOrderFront(nil)
                    focusSearch()
                }
            }
        }
    }

    private func showFullSearch() {
        let query = viewModel.query
        close()
        onShowFullSearch(query)
    }

    private func resize(to height: CGFloat) {
        guard let panel else { return }
        let visible = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        var frame = panel.frame
        let newHeight = min(height, (visible?.height ?? height + 32) - 32)
        frame.origin.y += frame.height - newHeight
        frame.size = NSSize(width: min(680 * scale, (visible?.width ?? 800) - 32), height: newHeight)
        if let visible { frame.origin.y = max(visible.minY + 16, frame.origin.y) }
        panel.setFrame(frame, display: panel.isVisible, animate: false)
    }

    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        guard let visible = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame
        else { panel.center(); return }
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - panel.frame.width / 2,
            y: max(visible.minY + 16, visible.maxY - visible.height * 0.23 - panel.frame.height)
        ))
    }

    func windowDidResignKey(_ notification: Notification) { close() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { close(); return false }
}

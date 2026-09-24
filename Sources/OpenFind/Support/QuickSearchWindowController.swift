import AppKit
import SwiftUI

@MainActor
final class QuickSearchWindowController: NSObject, NSWindowDelegate {
    let viewModel: QuickSearchViewModel
    private let onShowFullSearch: (String) -> Void
    private let onQuickLook: ([URL]) -> Void
    private let isQuickLookVisible: () -> Bool
    private let onDismiss: () -> Void
    private let sendGhosttyCommand: @Sendable (GhosttyCommand) async throws -> Void
    private(set) var panel: QuickSearchPanel?
    private weak var searchField: NSTextField?
    private var hostingView: NSHostingView<QuickSearchView>?
    private var scale: CGFloat = 1
    private var launchTask: Task<Void, Never>?
    private var requestingContactsAccess = false
    private var presentingQuickLook = false

    init(
        viewModel: QuickSearchViewModel = QuickSearchViewModel(),
        onShowFullSearch: @escaping (String) -> Void,
        onQuickLook: @escaping ([URL]) -> Void = { _ in },
        isQuickLookVisible: @escaping () -> Bool = { false },
        onDismiss: @escaping () -> Void = {},
        sendGhosttyCommand: @escaping @Sendable (GhosttyCommand) async throws -> Void = {
            try await GhosttyCommandRunner().send($0)
        }
    ) {
        self.viewModel = viewModel
        self.onShowFullSearch = onShowFullSearch
        self.onQuickLook = onQuickLook
        self.isQuickLookVisible = isQuickLookVisible
        self.onDismiss = onDismiss
        self.sendGhosttyCommand = sendGhosttyCommand
        super.init()
    }

    var isVisible: Bool { panel?.isVisible == true }

    func show() {
        if !viewModel.isSendingCommand { viewModel.prepareForPresentation() }
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
        panel?.orderOut(nil)
        if !viewModel.isSendingCommand { viewModel.releaseTransientResults() }
        onDismiss()
    }

    private func focusSearch(atEnd: Bool = false) {
        guard let panel, panel.isVisible, let searchField else { return }
        panel.makeKey()
        panel.makeFirstResponder(searchField)
        if atEnd, let editor = searchField.currentEditor() as? NSTextView {
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        }
    }

    func beginTerminalCommand() {
        guard !viewModel.isSendingCommand else { return }
        viewModel.selectMode(.terminal)
        focusSearch(atEnd: true)
        DispatchQueue.main.async { [weak self] in self?.focusSearch(atEnd: true) }
    }

    private func makeView() -> QuickSearchView {
        QuickSearchView(
            viewModel: viewModel, scale: scale,
            onOpen: { [weak self] in self?.open($0) },
            onRecentDocuments: { [weak self] item in
                guard let application = item.application else { return }
                self?.viewModel.showRecentDocuments(for: application)
            },
            onQuickLook: { [weak self] item in
                _ = self?.preview(item)
            },
            onFullSearch: { [weak self] in self?.showFullSearch() },
            onStartTerminalCommand: { [weak self] in self?.beginTerminalCommand() },
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
        panel.onClose = { [weak self] in
            guard let self else { return }
            if viewModel.contactDetail != nil { _ = viewModel.navigateBack() }
            else { close() }
        }
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
        panel.onNavigateForward = { [weak self] in
            guard let self else { return false }
            if viewModel.navigateIntoSelection() { return true }
            guard let application = viewModel.selectedResult?.application else { return false }
            viewModel.showRecentDocuments(for: application)
            return true
        }
        panel.onNavigateBack = { [weak self] in self?.viewModel.navigateBack() == true }
        panel.onQuickLook = { [weak self] explicitShortcut in
            guard let self, explicitShortcut || viewModel.hasExplicitSelection,
                  let result = viewModel.selectedResult else { return false }
            return preview(result)
        }
        panel.onMoveSelection = { [weak self] in self?.viewModel.moveSelection(by: $0) }
        panel.onOpenNumber = { [weak self] index in
            guard let self, viewModel.contactDetail == nil, viewModel.resultsAreCurrent,
                  viewModel.results.indices.contains(index) else { return }
            open(viewModel.results[index])
        }
        self.panel = panel
        let host = NSHostingView(rootView: makeView())
        host.sizingOptions = []
        panel.contentView = host
        hostingView = host
        return panel
    }

    @discardableResult
    func preview(_ item: QuickSearchItem) -> Bool {
        guard viewModel.contactDetail == nil, viewModel.resultsAreCurrent,
              viewModel.results.contains(item), item.url.isFileURL else { return false }
        presentingQuickLook = true
        defer { presentingQuickLook = false }
        onQuickLook([item.url])
        return true
    }

    func open(_ result: QuickSearchItem) {
        guard launchTask == nil, viewModel.contactDetail == nil, viewModel.resultsAreCurrent,
              viewModel.results.contains(result) else { return }
        viewModel.errorMessage = nil
        launchTask = Task { [weak self] in
            guard let self else { return }
            defer { launchTask = nil }
            do {
                switch result.action {
                case .fullSearch(let query):
                    close()
                    onShowFullSearch(query)
                    return
                case .requestContactsAccess:
                    requestingContactsAccess = true
                    _ = await ContactSearchIndex.requestAccess()
                    requestingContactsAccess = false
                    panel?.makeKeyAndOrderFront(nil)
                    focusSearch()
                    viewModel.scheduleSearch()
                    return
                case .showContact(let contact):
                    viewModel.showContact(contact)
                    return
                case .recentDocuments(let application):
                    viewModel.showRecentDocuments(for: application)
                    return
                case .openWithApplication(let applicationURL):
                    guard result.url.isFileURL else { throw CocoaError(.fileReadUnknown) }
                    let config = NSWorkspace.OpenConfiguration()
                    config.activates = true
                    config.createsNewApplicationInstance = false
                    _ = try await NSWorkspace.shared.open([result.url], withApplicationAt: applicationURL, configuration: config)
                    SearchUsageStore.shared.recordSuccessfulOpen(result.url)
                    close()
                    return
                case .copyText(let text):
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    close()
                    return
                case .system(let action):
                    try QuickSystemCommands.run(action)
                    close()
                    return
                case .ghostty(let commandText):
                    viewModel.isSendingCommand = true
                    do {
                        guard let ghostty = GhosttyCommand(input: commandText) else {
                            throw GhosttyCommandError.invalidCommand
                        }
                        try await sendGhosttyCommand(ghostty)
                        viewModel.isSendingCommand = false
                        close()
                    } catch {
                        viewModel.isSendingCommand = false
                        viewModel.errorMessage = (error as? GhosttyCommandError)?.userMessage
                            ?? L("Ghostty Send Failed")
                        if !isVisible {
                            panel?.makeKeyAndOrderFront(nil)
                        }
                        DispatchQueue.main.async { [weak self] in self?.focusSearch() }
                    }
                    return
                case .reveal:
                    guard result.url.isFileURL else { throw CocoaError(.fileReadUnknown) }
                    close()
                    FileActions.revealInFinder([result.url])
                    return
                case .open:
                    break
                }
                if result.isDirectory, viewModel.commandMode == .path {
                    viewModel.query = result.url.path + "/"
                    return
                }
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
                viewModel.errorMessage = error as? QuickSystemCommandError == .accessibilityRequired
                    ? L("System Command Permission Help") : L("Quick Search Open Failed")
                if !isVisible {
                    panel?.makeKeyAndOrderFront(nil)
                    focusSearch()
                }
            }
        }
    }

    private func showFullSearch() {
        guard viewModel.commandMode != .terminal, !viewModel.isSendingCommand else { return }
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

    func windowDidResignKey(_ notification: Notification) {
        if !requestingContactsAccess, !presentingQuickLook, !viewModel.isSendingCommand,
           !isQuickLookVisible() { close() }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { close(); return false }
}

import AppKit
import Carbon
import Foundation
import Testing
@testable import OpenFind

@MainActor
@Suite("Alfred-Inspired Clipboard Workflow Tests", .serialized)
struct ClipboardAlfredWorkflowTests {
    @Test func savingForReuseIsIdempotentAndKeepsTheSelectedEntry() throws {
        let context = try makeContext()
        try ingest(["newer", "older"], into: context.store)
        let older = try #require(context.store.entries.first { $0.previewText == "older" })
        context.store.select(older)

        #expect(context.store.saveForReuse(older))
        let saved = try #require(context.store.entries.first { $0.id == older.id })
        let assignedKey = try #require(saved.pinKey)
        #expect(saved.isPinned)
        #expect(context.store.selectedEntry?.id == older.id)

        #expect(context.store.saveForReuse(saved))
        let savedAgain = try #require(context.store.entries.first { $0.id == older.id })
        #expect(savedAgain.pinKey == assignedKey)
        #expect(savedAgain.isPinned)
    }

    @Test func recentClearPreservesSavedAndOlderEntries() throws {
        let context = try makeContext()
        let now = Date(timeIntervalSince1970: 10_000)
        #expect(context.store.ingest(
            representations: ["public.utf8-plain-text": Data("old".utf8)],
            previewText: "old",
            kind: .text,
            createdAt: now.addingTimeInterval(-16 * 60)
        ))
        #expect(context.store.ingest(
            representations: ["public.utf8-plain-text": Data("recent".utf8)],
            previewText: "recent",
            kind: .text,
            createdAt: now.addingTimeInterval(-4 * 60)
        ))
        #expect(context.store.ingest(
            representations: ["public.utf8-plain-text": Data("saved".utf8)],
            previewText: "saved",
            kind: .text,
            createdAt: now.addingTimeInterval(-60)
        ))
        let saved = try #require(context.store.entries.first { $0.previewText == "saved" })
        #expect(context.store.saveForReuse(saved))

        context.store.clearRecent(minutes: 5, referenceDate: now)

        #expect(Set(context.store.entries.map(\.previewText)) == ["old", "saved"])
        #expect(context.store.entries.first { $0.previewText == "saved" }?.isPinned == true)
    }

    @Test func mergeCopiesPlainTextInExplicitSelectionOrder() throws {
        let context = try makeContext()
        try ingest(["first", "second", "third"], into: context.store)
        let byTitle = Dictionary(uniqueKeysWithValues: context.store.entries.map {
            ($0.previewText, $0)
        })
        let ordered = [
            try #require(byTitle["second"]),
            try #require(byTitle["first"]),
            try #require(byTitle["third"]),
        ]

        #expect(context.store.canMergePlainText(ordered))
        try context.store.copyMergedPlainText(ordered)

        #expect(context.pasteboard.string(forType: .string) == "second\nfirst\nthird")
    }

    @Test func actionContextIsTypeAwareForSingleAndMultipleItems() {
        let text = entry("text", kind: .text)
        let single = ClipboardPanelActionContext(
            entry: text,
            selectedEntries: [text],
            canCopyPlainText: true,
            canMergePlainText: false,
            hasOpenableURL: false,
            hasFiles: false
        )
        #expect(single.itemActions == [
            .paste, .pastePlainText, .copy, .copyPlainText, .quickLookFiles,
            .saveForReuse, .delete,
        ])

        var savedURL = entry("https://openfind.example", kind: .url)
        savedURL.isPinned = true
        let link = ClipboardPanelActionContext(
            entry: savedURL,
            selectedEntries: [savedURL],
            canCopyPlainText: true,
            canMergePlainText: false,
            hasOpenableURL: true,
            hasFiles: false
        )
        #expect(link.itemActions.contains(.openURL))
        #expect(link.itemActions.contains(.removeFromSaved))
        #expect(!link.itemActions.contains(.saveForReuse))

        let file = entry("file", kind: .file)
        let fileContext = ClipboardPanelActionContext(
            entry: file,
            selectedEntries: [file],
            canCopyPlainText: false,
            canMergePlainText: false,
            hasOpenableURL: false,
            hasFiles: true
        )
        #expect(fileContext.itemActions == [
            .paste,
            .copy,
            .openFiles,
            .revealFiles,
            .quickLookFiles,
            .saveForReuse,
            .delete,
        ])

        let second = entry("second", kind: .text)
        let multiple = ClipboardPanelActionContext(
            entry: text,
            selectedEntries: [second, text],
            canCopyPlainText: true,
            canMergePlainText: true,
            hasOpenableURL: false,
            hasFiles: false
        )
        #expect(multiple.itemActions == [
            .pasteSelection,
            .pasteSelectionPlainText,
            .mergeSelectionPlainText,
            .delete,
        ])

        let mixedSelection = ClipboardPanelActionContext(
            entry: text,
            selectedEntries: [file, text],
            canCopyPlainText: true,
            canMergePlainText: false,
            hasOpenableURL: false,
            hasFiles: false
        )
        #expect(mixedSelection.itemActions == [.pasteSelection, .delete])
    }

    @Test func shortcutActivationHidesMainAndSettingsWindows() throws {
        let context = try makeContext()
        var activationCount = 0
        let controller = ClipboardHistoryWindowController(
            store: context.store,
            applicationActivator: { activationCount += 1 }
        )
        let mainWindow = testWindow(identifier: "OpenFind.main")
        let settingsWindow = testWindow(identifier: "OpenFind.settings")
        let companionWindow = testWindow(identifier: nil)
        mainWindow.orderFront(nil)
        settingsWindow.orderFront(nil)
        companionWindow.orderFront(nil)
        defer {
            mainWindow.orderOut(nil)
            settingsWindow.orderOut(nil)
            companionWindow.orderOut(nil)
        }

        #expect(mainWindow.isVisible)
        #expect(settingsWindow.isVisible)
        #expect(companionWindow.isVisible)

        controller.activateForClipboardPanel(hideApplicationWindows: true)

        #expect(!mainWindow.isVisible)
        #expect(!settingsWindow.isVisible)
        #expect(!companionWindow.isVisible)
        #expect(mainWindow.animationBehavior == .none)
        #expect(settingsWindow.animationBehavior == .none)
        #expect(companionWindow.animationBehavior == .none)
        #expect(activationCount == 1)

        let panel = controller.makePanelIfNeeded()
        #expect(!panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.animationBehavior == .none)
        #expect(panel.hidesOnDeactivate)
    }

    @Test func preparingClipboardPanelKeepsAnImperceptibleNonInteractiveSurfaceWarm() throws {
        let context = try makeContext()
        let controller = ClipboardHistoryWindowController(store: context.store)

        controller.prepare()

        let panel = try #require(controller.panel)
        #expect(panel.isVisible)
        #expect(panel.alphaValue == 0.49)
        #expect(panel.contentView?.alphaValue == 0.001)
        #expect(panel.ignoresMouseEvents)
        #expect(!panel.hasShadow)
        #expect(!panel.isKeyWindow)
        #expect(panel.contentView != nil)
        #expect(context.store.isPreviewVisible)
    }

    @Test func backgroundResidenceDoesNotClaimKeyboardFocusWhileHidden() throws {
        let context = try makeContext()
        let controller = ClipboardHistoryWindowController(store: context.store)

        controller.prepareForBackgroundResidence()

        let panel = try #require(controller.panel)
        #expect(!panel.isKeyWindow)
        #expect(panel.alphaValue == 0.49)
        #expect(panel.contentView?.alphaValue == 0.001)
        #expect(panel.ignoresMouseEvents)
        #expect(!context.store.isPanelPresented)
        controller.close()
    }

    @Test func presentedClipboardPanelTargetsSearchFieldForKeyboardFocus() async throws {
        let context = try makeContext()
        let controller = ClipboardHistoryWindowController(store: context.store)
        controller.prepareForBackgroundResidence()

        controller.present(positionOverride: .center, hideApplicationWindows: true)
        defer { controller.close() }

        let panel = try #require(controller.panel)
        let searchIsFirstResponder = await waitForSearchFirstResponder(in: panel)
        #expect(searchIsFirstResponder)
    }

    @Test func closingPresentedClipboardPanelReturnsApplicationFocus() throws {
        let context = try makeContext()
        var deactivationCount = 0
        let controller = ClipboardHistoryWindowController(
            store: context.store,
            applicationActivator: {},
            applicationDeactivator: { deactivationCount += 1 }
        )

        controller.present(positionOverride: .center, hideApplicationWindows: true)
        controller.close()

        #expect(!context.store.isPanelPresented)
        #expect(deactivationCount == 1)
    }

    @Test func shortcutRestoresSavedClipboardPanelSizeAndPosition() throws {
        let context = try makeContext()
        let frameName = "OpenFindTests.ClipboardFrame.\(UUID())"
        defer { removeSavedFrame(named: frameName) }
        let expectedFrame = try testPanelFrame(width: 880, height: 580)
        let writer = ClipboardHistoryPanel(
            contentRect: .zero,
            styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        writer.setFrame(expectedFrame, display: false)
        writer.saveFrame(usingName: frameName)
        context.store.setPreference(\.popupPosition, to: .lastPosition)
        let controller = ClipboardHistoryWindowController(
            store: context.store,
            frameAutosaveName: frameName
        )

        controller.prepareForBackgroundResidence()
        controller.show()
        defer { controller.close() }

        let panel = try #require(controller.panel)
        #expect(framesMatch(panel.frame, expectedFrame))
    }

    @Test func manualResizeAndMoveBecomeTheNextClipboardPanelFrame() throws {
        let context = try makeContext()
        let frameName = "OpenFindTests.ClipboardFrame.\(UUID())"
        defer { removeSavedFrame(named: frameName) }
        let controller = ClipboardHistoryWindowController(
            store: context.store,
            frameAutosaveName: frameName
        )
        let panel = controller.makePanelIfNeeded()
        let resizedFrame = try testPanelFrame(width: 900, height: 600)

        controller.windowWillStartLiveResize(
            Notification(name: NSWindow.willStartLiveResizeNotification, object: panel)
        )
        panel.setFrame(resizedFrame, display: false)
        controller.windowDidEndLiveResize(
            Notification(name: NSWindow.didEndLiveResizeNotification, object: panel)
        )

        #expect(context.store.preferences.popupPosition == .lastPosition)

        context.store.setPreference(\.popupPosition, to: .center)
        controller.windowWillMove(
            Notification(name: NSWindow.willMoveNotification, object: panel)
        )
        var movedFrame = panel.frame
        movedFrame.origin.x += 36
        movedFrame.origin.y -= 24
        panel.setFrame(movedFrame, display: false)
        controller.windowDidMove(
            Notification(name: NSWindow.didMoveNotification, object: panel)
        )

        #expect(context.store.preferences.popupPosition == .lastPosition)
        controller.close()

        let reopenedController = ClipboardHistoryWindowController(
            store: context.store,
            frameAutosaveName: frameName
        )
        reopenedController.prepareForBackgroundResidence()
        reopenedController.show()
        defer { reopenedController.close() }

        let reopenedPanel = try #require(reopenedController.panel)
        #expect(framesMatch(reopenedPanel.frame, movedFrame))
    }

    @Test func commandActionsPrecedeTheIMECompositionGuard() throws {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: panel.contentView?.bounds ?? .zero)
        let hostView = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        let markedTextView = AlwaysMarkedTextView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        container.addSubview(hostView)
        container.addSubview(markedTextView)
        panel.contentView = container
        panel.orderFront(nil)
        defer { panel.orderOut(nil) }
        #expect(panel.makeFirstResponder(markedTextView))
        #expect(markedTextView.hasMarkedText())

        var actionPanelToggleCount = 0
        var saveCount = 0
        func makeHandler(isPanelPresented: Bool) -> ClipboardHistoryKeyMonitor {
            ClipboardHistoryKeyMonitor(
                isPanelPresented: isPanelPresented,
                isSearchPresented: true,
                isActionPanelPresented: false,
                pinShortcut: ClipboardPreferences.defaultPinShortcut,
                deleteShortcut: ClipboardPreferences.defaultDeleteShortcut,
                previewShortcut: ClipboardPreferences.defaultPreviewShortcut,
                onMove: { _ in },
                onSelectBoundary: { _ in },
                onExtend: { _ in },
                onExtendBoundary: { _ in },
                onDefaultAction: {},
                onPaste: { _ in },
                onCopyPlainText: {},
                onTogglePin: {},
                onSaveForReuse: { saveCount += 1 },
                onToggleActions: { actionPanelToggleCount += 1 },
                onTogglePreview: {},
                onDelete: {},
                onClear: { _ in },
                onUndo: {},
                onEscape: {},
                onBeginSearch: { _ in },
                onQuickAction: { _, _ in },
                onPinnedAction: { _, _ in }
            )
        }
        let coordinator = ClipboardHistoryKeyMonitor.Coordinator()
        coordinator.hostView = hostView
        coordinator.handler = makeHandler(isPanelPresented: true)

        let commandK = try #require(keyEvent(keyCode: kVK_ANSI_K, characters: "k"))
        let commandS = try #require(keyEvent(keyCode: kVK_ANSI_S, characters: "s"))
        #expect(coordinator.handle(commandK) == nil)
        #expect(coordinator.handle(commandS) == nil)
        #expect(actionPanelToggleCount == 1)
        #expect(saveCount == 1)

        coordinator.handler = makeHandler(isPanelPresented: false)
        #expect(coordinator.handle(commandK) === commandK)
        #expect(actionPanelToggleCount == 1)
    }

    private func testWindow(identifier: String?) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: .titled,
            backing: .buffered,
            defer: false
        )
        if let identifier {
            window.identifier = NSUserInterfaceItemIdentifier(identifier)
        }
        return window
    }

    @Test func panelKeyEquivalentsProvideAResponderChainFallback() throws {
        let panel = ClipboardHistoryPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        var actionPanelToggleCount = 0
        var saveCount = 0
        var closeCount = 0
        panel.onToggleActions = { actionPanelToggleCount += 1 }
        panel.onSaveForReuse = { saveCount += 1 }
        panel.onClose = { closeCount += 1 }

        let commandK = try #require(keyEvent(keyCode: kVK_ANSI_K, characters: "k"))
        let commandS = try #require(keyEvent(keyCode: kVK_ANSI_S, characters: "s"))
        let escape = try #require(keyEvent(
            keyCode: kVK_Escape,
            characters: "\u{1b}",
            modifierFlags: []
        ))
        #expect(panel.performKeyEquivalent(with: commandK))
        #expect(panel.performKeyEquivalent(with: commandS))
        #expect(panel.performKeyEquivalent(with: escape))
        #expect(actionPanelToggleCount == 1)
        #expect(saveCount == 1)
        #expect(closeCount == 1)

        panel.sendEvent(commandK)
        panel.sendEvent(commandS)
        panel.sendEvent(escape)
        #expect(actionPanelToggleCount == 2)
        #expect(saveCount == 2)
        #expect(closeCount == 2)
    }

    @Test func escapeClosesClipboardPanelEvenWhenSearchHasText() throws {
        let context = try makeContext()
        let controller = ClipboardHistoryWindowController(store: context.store)
        context.store.beginPresentation()
        context.store.query = "needle"

        controller.makeHistoryView().handleEscape()

        #expect(!context.store.isPanelPresented)
    }

    private func entry(_ text: String, kind: ClipboardEntryKind) -> ClipboardEntry {
        ClipboardEntry(
            previewText: text,
            kind: kind,
            representations: ["public.utf8-plain-text": Data(text.utf8)]
        )
    }

    private func ingest(_ values: [String], into store: ClipboardHistoryStore) throws {
        for (index, value) in values.enumerated() {
            #expect(store.ingest(
                representations: ["public.utf8-plain-text": Data(value.utf8)],
                previewText: value,
                kind: .text,
                createdAt: Date(timeIntervalSince1970: TimeInterval(index + 1))
            ))
        }
    }

    private func makeContext() throws -> AlfredWorkflowContext {
        let suite = "OpenFindTests.ClipboardAlfredWorkflow.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let pasteboard = NSPasteboard(name: .init("OpenFindTests.\(UUID())"))
        return AlfredWorkflowContext(
            store: ClipboardHistoryStore(
                defaults: defaults,
                persistence: AlfredWorkflowMemoryPersistence(),
                pasteboard: pasteboard
            ),
            pasteboard: pasteboard
        )
    }

    private func testPanelFrame(width: CGFloat, height: CGFloat) throws -> NSRect {
        let visibleFrame = try #require(NSScreen.main?.visibleFrame)
        let size = NSSize(
            width: min(width, visibleFrame.width - 80),
            height: min(height, visibleFrame.height - 80)
        )
        return NSRect(
            x: visibleFrame.minX + 40,
            y: visibleFrame.maxY - size.height - 40,
            width: size.width,
            height: size.height
        )
    }

    private func framesMatch(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) < 1
            && abs(lhs.origin.y - rhs.origin.y) < 1
            && abs(lhs.width - rhs.width) < 1
            && abs(lhs.height - rhs.height) < 1
    }

    private func removeSavedFrame(named name: NSWindow.FrameAutosaveName) {
        UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(name)")
    }

    private func waitForSearchFirstResponder(in panel: NSPanel) async -> Bool {
        for _ in 0..<20 {
            if panel.firstResponder is NSTextView {
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    private func keyEvent(
        keyCode: Int,
        characters: String,
        modifierFlags: NSEvent.ModifierFlags = .command
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: UInt16(keyCode)
        )
    }
}

private final class AlwaysMarkedTextView: NSTextView {
    override func hasMarkedText() -> Bool { true }
}

private struct AlfredWorkflowContext {
    let store: ClipboardHistoryStore
    let pasteboard: NSPasteboard
}

private final class AlfredWorkflowMemoryPersistence: ClipboardHistoryPersisting {
    var requiresExplicitMigration = false
    private var entries: [ClipboardEntry] = []

    func load() throws -> [ClipboardEntry] { entries }
    func save(_ entries: [ClipboardEntry]) throws { self.entries = entries }
    func remove() throws { entries = [] }
}

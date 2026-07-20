import AppKit
import Foundation

/// A non-activating, mouse-operated escape hatch for keyboard-cleaning mode.
/// It deliberately has no key equivalent: while the event tap is active every
/// software-visible keyboard event remains suppressed.
@MainActor
final class KeyboardUnlockPanelController: NSObject {
    private var panel: NSPanel?
    private var elapsedLabel: NSTextField?
    private var elapsedTask: Task<Void, Never>?
    private var unlockAction: (@MainActor () -> Void)?

    func show(lockedAt: Date, unlockAction: @escaping @MainActor () -> Void) {
        self.unlockAction = unlockAction
        let panel = makePanelIfNeeded()
        position(panel)
        panel.orderFrontRegardless()
        startElapsedUpdates(lockedAt: lockedAt)
    }

    func hide() {
        elapsedTask?.cancel()
        elapsedTask = nil
        panel?.orderOut(nil)
        unlockAction = nil
    }

    private func makePanelIfNeeded() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 330, height: 154),
            styleMask: [.titled, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = L("Keyboard Locked")
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        let title = NSTextField(labelWithString: L("Keyboard Locked"))
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        title.alignment = .center

        let help = NSTextField(wrappingLabelWithString: L("Keyboard Lock Pointer Help"))
        help.textColor = .secondaryLabelColor
        help.alignment = .center
        help.maximumNumberOfLines = 2

        let elapsed = NSTextField(labelWithString: "")
        elapsed.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        elapsed.textColor = .secondaryLabelColor
        elapsed.alignment = .center
        elapsedLabel = elapsed

        let button = NSButton(
            title: L("Unlock Keyboard"),
            target: self,
            action: #selector(unlockWithPointer(_:))
        )
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.keyEquivalent = ""
        button.setAccessibilityLabel(L("Unlock Keyboard"))

        let stack = NSStackView(views: [title, help, elapsed, button])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = NSView()
        panel.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -18),
            stack.centerYAnchor.constraint(equalTo: panel.contentView!.centerYAnchor),
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),
        ])

        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            panel.center()
            return
        }
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - panel.frame.width / 2,
            y: visible.maxY - panel.frame.height - 44
        ))
    }

    private func startElapsedUpdates(lockedAt: Date) {
        elapsedTask?.cancel()
        elapsedTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let seconds = max(0, Int(Date().timeIntervalSince(lockedAt)))
                self?.elapsedLabel?.stringValue = String(
                    format: L("Keyboard Lock Elapsed Format"),
                    seconds / 3_600,
                    seconds % 3_600 / 60,
                    seconds % 60
                )
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }
        }
    }

    @objc private func unlockWithPointer(_ sender: Any?) {
        unlockAction?()
    }
}

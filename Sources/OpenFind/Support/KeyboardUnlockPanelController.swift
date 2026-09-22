import AppKit
import Foundation

/// A non-activating, mouse-operated escape hatch for keyboard-cleaning mode.
/// It deliberately has no key equivalent: while the event tap is active every
/// software-visible keyboard event remains suppressed.
@MainActor
final class KeyboardUnlockPanelController: NSObject {
    private var panel: NSPanel?
    private var backgroundView: KeyboardUnlockBackgroundView?
    private var opacitySlider: NSSlider?
    private var opacityLabel: NSTextField?
    private var opacityChanged: (@MainActor (Double) -> Void)?
    private var accessibilityObserver: NSObjectProtocol?
    private var elapsedLabel: NSTextField?
    private var elapsedTask: Task<Void, Never>?
    private var unlockAction: (@MainActor () -> Void)?

    func show(
        lockedAt: Date,
        backgroundOpacity: Double,
        opacityChanged: @escaping @MainActor (Double) -> Void,
        unlockAction: @escaping @MainActor () -> Void
    ) {
        self.unlockAction = unlockAction
        self.opacityChanged = opacityChanged
        let panel = makePanelIfNeeded()
        setBackgroundOpacity(backgroundOpacity)
        backgroundView?.resetPointerState()
        if accessibilityObserver == nil {
            accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.backgroundView?.needsDisplay = true }
            }
        }
        position(panel)
        panel.orderFrontRegardless()
        startElapsedUpdates(lockedAt: lockedAt)
    }

    func hide() {
        elapsedTask?.cancel()
        elapsedTask = nil
        panel?.orderOut(nil)
        unlockAction = nil
        opacityChanged = nil
        if let accessibilityObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver)
            self.accessibilityObserver = nil
        }
    }

    func setBackgroundOpacity(_ opacity: Double) {
        let value = KeyboardLockController.normalizedPanelOpacity(opacity)
        backgroundView?.backgroundOpacity = CGFloat(value)
        opacitySlider?.doubleValue = value
        opacityLabel?.stringValue = value.formatted(.percent.precision(.fractionLength(0)))
    }

    private func makePanelIfNeeded() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 210),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = L("Keyboard Locked")
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let background = KeyboardUnlockBackgroundView()
        backgroundView = background

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

        let opacityTitle = NSTextField(labelWithString: L("Keyboard Lock Panel Opacity"))
        opacityTitle.font = .systemFont(ofSize: 12)
        let slider = NSSlider(
            value: KeyboardLockController.defaultPanelOpacity,
            minValue: KeyboardLockController.panelOpacityRange.lowerBound,
            maxValue: KeyboardLockController.panelOpacityRange.upperBound,
            target: self,
            action: #selector(changeOpacity(_:))
        )
        slider.isContinuous = true
        slider.setAccessibilityLabel(L("Keyboard Lock Panel Opacity"))
        opacitySlider = slider
        let value = NSTextField(labelWithString: "")
        value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        value.alignment = .right
        opacityLabel = value
        let opacityControls = NSStackView(views: [slider, value])
        opacityControls.spacing = 8
        let stack = NSStackView(views: [title, help, elapsed, opacityTitle, opacityControls, button])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = background
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -18),
            stack.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            opacityControls.widthAnchor.constraint(equalTo: stack.widthAnchor),
            value.widthAnchor.constraint(equalToConstant: 42),
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

    @objc private func changeOpacity(_ sender: NSSlider) {
        // Preview while dragging; restore hover legibility on the next entry.
        backgroundView?.previewOpacity = true
        let value = (sender.doubleValue * 20).rounded() / 20
        setBackgroundOpacity(value)
        opacityChanged?(value)
    }
}

@MainActor
private final class KeyboardUnlockBackgroundView: NSView {
    var backgroundOpacity: CGFloat = 0.85 { didSet { needsDisplay = true } }
    var previewOpacity = false { didSet { needsDisplay = true } }
    private var pointerInside = false
    private var pointerTrackingArea: NSTrackingArea?

    override var mouseDownCanMoveWindow: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        pointerTrackingArea = area
    }

    func resetPointerState() {
        pointerInside = false
        previewOpacity = false
    }

    override func mouseEntered(with event: NSEvent) {
        pointerInside = true
        previewOpacity = false
    }

    override func mouseExited(with event: NSEvent) {
        pointerInside = false
        previewOpacity = false
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let workspace = NSWorkspace.shared
        let opaque = workspace.accessibilityDisplayShouldReduceTransparency
            || workspace.accessibilityDisplayShouldIncreaseContrast
            || (pointerInside && !previewOpacity)
        NSColor.windowBackgroundColor.withAlphaComponent(opaque ? 1 : backgroundOpacity).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14).fill()
    }
}

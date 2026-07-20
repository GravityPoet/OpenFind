import AppKit

@MainActor
protocol AwakeNotificationBannerPresenting: AnyObject {
    func present(_ payload: AwakeNotificationPayload)
    func dismiss()
}

@MainActor
final class OpenFindNotificationBannerPresenter: NSObject, AwakeNotificationBannerPresenting {
    private static let panelSize = NSSize(width: 372, height: 112)
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    func present(_ payload: AwakeNotificationPayload) {
        dismiss()

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .transient,
            .ignoresCycle,
        ]
        panel.animationBehavior = .utilityWindow
        panel.contentView = makeContentView(payload)
        panel.setFrameOrigin(origin(for: panel.frame.size))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.animator().alphaValue = 1
        self.panel = panel

        if payload.playsSound {
            if let sound = NSSound(named: NSSound.Name("Glass")) {
                sound.play()
            } else {
                NSSound.beep()
            }
        }

        dismissTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(6))
            } catch {
                return
            }
            self?.dismiss()
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        panel?.orderOut(nil)
        panel = nil
    }

    @objc private func dismissFromButton() {
        dismiss()
    }

    private func makeContentView(_ payload: AwakeNotificationPayload) -> NSView {
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.55).cgColor

        let icon = NSImageView(image: NSApplication.shared.applicationIconImage)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown

        let title = NSTextField(labelWithString: payload.title)
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail

        let body = NSTextField(wrappingLabelWithString: payload.body)
        body.translatesAutoresizingMaskIntoConstraints = false
        body.font = .systemFont(ofSize: 12.5)
        body.textColor = .secondaryLabelColor
        body.maximumNumberOfLines = 2
        body.lineBreakMode = .byTruncatingTail

        let labels = NSStackView(views: [title, body])
        labels.translatesAutoresizingMaskIntoConstraints = false
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 4

        let close = NSButton(
            image: NSImage(
                systemSymbolName: "xmark.circle.fill",
                accessibilityDescription: L("Dismiss Notification")
            ) ?? NSImage(),
            target: self,
            action: #selector(dismissFromButton)
        )
        close.translatesAutoresizingMaskIntoConstraints = false
        close.isBordered = false
        close.contentTintColor = .tertiaryLabelColor
        close.toolTip = L("Dismiss Notification")
        close.setAccessibilityLabel(L("Dismiss Notification"))

        effect.addSubview(icon)
        effect.addSubview(labels)
        effect.addSubview(close)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 16),
            icon.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 44),
            icon.heightAnchor.constraint(equalToConstant: 44),

            labels.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 13),
            labels.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
            labels.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -10),

            close.topAnchor.constraint(equalTo: effect.topAnchor, constant: 10),
            close.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -10),
            close.widthAnchor.constraint(equalToConstant: 22),
            close.heightAnchor.constraint(equalToConstant: 22),
        ])
        return effect
    }

    private func origin(for size: NSSize) -> NSPoint {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first {
            NSMouseInRect(mouseLocation, $0.frame, false)
        } ?? NSScreen.main ?? NSScreen.screens.first
        guard let visibleFrame = screen?.visibleFrame else { return .zero }
        return NSPoint(
            x: visibleFrame.maxX - size.width - 16,
            y: visibleFrame.maxY - size.height - 16
        )
    }
}

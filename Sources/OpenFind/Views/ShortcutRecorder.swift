import AppKit
import Carbon
import SwiftUI

struct ShortcutRecorder: NSViewRepresentable {
    let shortcut: GlobalShortcut
    let prompt: String
    let accessibilityLabel: String
    let onChange: (GlobalShortcut) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton(title: shortcut.displayText, target: nil, action: nil)
        button.bezelStyle = .rounded
        button.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.target = context.coordinator
        button.action = #selector(Coordinator.beginRecording(_:))
        context.coordinator.button = button
        update(button, coordinator: context.coordinator)
        return button
    }

    func updateNSView(_ button: RecorderButton, context: Context) {
        context.coordinator.onChange = onChange
        update(button, coordinator: context.coordinator)
    }

    private func update(_ button: RecorderButton, coordinator: Coordinator) {
        button.shortcut = shortcut
        button.prompt = prompt
        button.setAccessibilityLabel(accessibilityLabel)
        button.setAccessibilityValue(shortcut.displayText)
        if !button.isRecording {
            button.title = shortcut.displayText
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var button: RecorderButton?
        var onChange: (GlobalShortcut) -> Void

        init(onChange: @escaping (GlobalShortcut) -> Void) {
            self.onChange = onChange
        }

        @objc func beginRecording(_ sender: RecorderButton) {
            sender.beginRecording { [weak self] shortcut in
                self?.onChange(shortcut)
            }
        }
    }
}

@MainActor
final class RecorderButton: NSButton {
    var shortcut = GlobalShortcut.defaultValue
    var prompt = ""
    private var capture: ((GlobalShortcut) -> Void)?
    private(set) var isRecording = false

    override var acceptsFirstResponder: Bool { true }

    func beginRecording(capture: @escaping (GlobalShortcut) -> Void) {
        self.capture = capture
        isRecording = true
        title = prompt
        window?.makeFirstResponder(self)
        setAccessibilityValue(prompt)
    }

    override func keyDown(with event: NSEvent) {
        if Int(event.keyCode) == kVK_Escape {
            finishRecording(display: shortcut.displayText)
            return
        }
        guard let shortcut = GlobalShortcut(event: event) else {
            NSSound.beep()
            return
        }
        self.shortcut = shortcut
        capture?(shortcut)
        finishRecording(display: shortcut.displayText)
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned, isRecording {
            finishRecording(display: shortcut.displayText, resign: false)
        }
        return resigned
    }

    private func finishRecording(display: String, resign: Bool = true) {
        isRecording = false
        capture = nil
        title = display
        setAccessibilityValue(display)
        if resign {
            window?.makeFirstResponder(nil)
        }
    }
}

import AppKit
import Carbon
import CoreGraphics
import Foundation
import Observation

enum ClipboardSnippetExpansionError: Error, Equatable, LocalizedError {
    case permissionRequired
    case targetUnavailable
    case eventCreationFailed

    var errorDescription: String? {
        switch self {
        case .permissionRequired:
            L("Snippet Expansion Permission Required")
        case .targetUnavailable:
            L("Snippet Expansion Target Unavailable")
        case .eventCreationFailed:
            L("Snippet Expansion Event Failed")
        }
    }
}

struct ClipboardSnippetTypingBuffer: Equatable, Sendable {
    private(set) var text = ""
    private(set) var processIdentifier: pid_t?
    private var lastEventAt: TimeInterval?
    let maximumLength: Int
    let timeout: TimeInterval

    init(maximumLength: Int = 64, timeout: TimeInterval = 10) {
        self.maximumLength = max(1, maximumLength)
        self.timeout = max(0.1, timeout)
    }

    mutating func consume(
        characters: String?,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        processIdentifier: pid_t,
        timestamp: TimeInterval
    ) -> String {
        let relevantModifiers = modifiers.intersection([.command, .control, .option])
        if self.processIdentifier != processIdentifier
            || lastEventAt.map({ timestamp - $0 > timeout }) == true
            || !relevantModifiers.isEmpty {
            reset()
        }
        self.processIdentifier = processIdentifier
        lastEventAt = timestamp

        if Int(keyCode) == kVK_Delete {
            if !text.isEmpty { text.removeLast() }
            return text
        }
        guard let characters,
              !characters.isEmpty,
              characters.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }),
              relevantModifiers.isEmpty else {
            reset()
            return text
        }
        text.append(contentsOf: characters)
        if text.count > maximumLength {
            text = String(text.suffix(maximumLength))
        }
        return text
    }

    mutating func reset() {
        text = ""
        processIdentifier = nil
        lastEventAt = nil
    }
}

@MainActor
protocol ClipboardSnippetEventPosting: AnyObject {
    func replaceTypedKeyword(
        characterCount: Int,
        with snippet: RenderedClipboardSnippet,
        in processIdentifier: pid_t
    ) async throws
}

@MainActor
final class SystemClipboardSnippetEventPoster: ClipboardSnippetEventPosting {
    func replaceTypedKeyword(
        characterCount: Int,
        with snippet: RenderedClipboardSnippet,
        in processIdentifier: pid_t
    ) async throws {
        guard AccessibilityPermission.isTrusted else {
            throw ClipboardSnippetExpansionError.permissionRequired
        }
        guard processIdentifier > 0 else {
            throw ClipboardSnippetExpansionError.targetUnavailable
        }
        let source = CGEventSource(stateID: .hidSystemState)
        for _ in 0..<characterCount {
            try postKey(
                CGKeyCode(kVK_Delete),
                source: source,
                processIdentifier: processIdentifier
            )
        }
        try await Task.sleep(for: .milliseconds(12))
        for chunk in unicodeChunks(snippet.text, maximumUTF16Units: 20) {
            try postUnicode(
                chunk,
                source: source,
                processIdentifier: processIdentifier
            )
        }
        for _ in 0..<snippet.cursorOffsetFromEnd {
            try postKey(
                CGKeyCode(kVK_LeftArrow),
                source: source,
                processIdentifier: processIdentifier
            )
        }
    }

    private func postKey(
        _ keyCode: CGKeyCode,
        source: CGEventSource?,
        processIdentifier: pid_t
    ) throws {
        guard let keyDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: keyCode,
            keyDown: true
        ), let keyUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: keyCode,
            keyDown: false
        ) else {
            throw ClipboardSnippetExpansionError.eventCreationFailed
        }
        keyDown.postToPid(processIdentifier)
        keyUp.postToPid(processIdentifier)
    }

    private func postUnicode(
        _ text: String,
        source: CGEventSource?,
        processIdentifier: pid_t
    ) throws {
        guard let keyDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: 0,
            keyDown: true
        ), let keyUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: 0,
            keyDown: false
        ) else {
            throw ClipboardSnippetExpansionError.eventCreationFailed
        }
        let units = Array(text.utf16)
        units.withUnsafeBufferPointer { buffer in
            keyDown.keyboardSetUnicodeString(
                stringLength: buffer.count,
                unicodeString: buffer.baseAddress
            )
        }
        keyDown.postToPid(processIdentifier)
        keyUp.postToPid(processIdentifier)
    }

    private func unicodeChunks(
        _ text: String,
        maximumUTF16Units: Int
    ) -> [String] {
        guard !text.isEmpty else { return [] }
        var chunks: [String] = []
        var current = ""
        var currentUnits = 0
        for character in text {
            let value = String(character)
            let units = value.utf16.count
            if !current.isEmpty, currentUnits + units > maximumUTF16Units {
                chunks.append(current)
                current = ""
                currentUnits = 0
            }
            current.append(character)
            currentUnits += units
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}

@MainActor
@Observable
final class ClipboardSnippetExpansionController {
    @ObservationIgnored private let store: ClipboardHistoryStore
    @ObservationIgnored private let workspace: NSWorkspace
    @ObservationIgnored private let pasteboard: NSPasteboard
    @ObservationIgnored private let eventPoster: any ClipboardSnippetEventPosting
    @ObservationIgnored private let ownProcessIdentifier: pid_t
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var buffer = ClipboardSnippetTypingBuffer(
        maximumLength: ClipboardHistoryStore.maximumSnippetKeywordLength
    )
    private(set) var isRunning = false
    private(set) var isExpanding = false
    private(set) var lastErrorMessage: String?

    init(
        store: ClipboardHistoryStore,
        workspace: NSWorkspace = .shared,
        pasteboard: NSPasteboard = .general,
        eventPoster: any ClipboardSnippetEventPosting = SystemClipboardSnippetEventPoster(),
        ownProcessIdentifier: pid_t = ProcessInfo.processInfo.processIdentifier
    ) {
        self.store = store
        self.workspace = workspace
        self.pasteboard = pasteboard
        self.eventPoster = eventPoster
        self.ownProcessIdentifier = ownProcessIdentifier
    }

    func refresh() {
        store.preferences.snippetExpansionEnabled ? start() : stop()
    }

    func start() {
        guard store.preferences.snippetExpansionEnabled else {
            stop()
            return
        }
        guard AccessibilityPermission.isTrusted else {
            stop()
            lastErrorMessage = ClipboardSnippetExpansionError.permissionRequired.localizedDescription
            return
        }
        guard monitor == nil else {
            isRunning = true
            lastErrorMessage = nil
            return
        }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor [weak self] in self?.handle(event) }
        }
        isRunning = monitor != nil
        lastErrorMessage = isRunning
            ? nil : ClipboardSnippetExpansionError.eventCreationFailed.localizedDescription
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        buffer.reset()
        isRunning = false
        isExpanding = false
    }

    func clearError() {
        lastErrorMessage = nil
    }

    private func handle(_ event: NSEvent) {
        guard isRunning, !isExpanding,
              let application = workspace.frontmostApplication,
              application.processIdentifier != ownProcessIdentifier,
              !application.isTerminated else {
            buffer.reset()
            return
        }
        let bundleIdentifier = application.bundleIdentifier
        if let bundleIdentifier,
           store.preferences.ignoredBundleIdentifiers.contains(bundleIdentifier) {
            buffer.reset()
            return
        }
        if store.preferences.captureOnlyFromAllowedApplications,
           bundleIdentifier.map({
               !store.preferences.allowedBundleIdentifiers.contains($0)
           }) ?? true {
            buffer.reset()
            return
        }
        let typed = buffer.consume(
            characters: event.characters,
            keyCode: event.keyCode,
            modifiers: event.modifierFlags,
            processIdentifier: application.processIdentifier,
            timestamp: event.timestamp
        )
        guard let entry = store.snippetEntry(matchingSuffix: typed),
              let keyword = entry.snippetKeyword,
              let template = store.plainText(for: entry) else { return }
        buffer.reset()
        let rendered = ClipboardSnippetRenderer.render(
            template,
            clipboardText: { [pasteboard] in pasteboard.string(forType: .string) }
        )
        isExpanding = true
        let processIdentifier = application.processIdentifier
        Task { @MainActor [weak self, eventPoster] in
            do {
                // Let the target application consume the final keyword key-down
                // before replacing the already typed text.
                try await Task.sleep(for: .milliseconds(24))
                try await eventPoster.replaceTypedKeyword(
                    characterCount: keyword.count,
                    with: rendered,
                    in: processIdentifier
                )
                self?.lastErrorMessage = nil
            } catch {
                self?.lastErrorMessage = (error as? LocalizedError)?.errorDescription
                    ?? L("Snippet Expansion Failed")
            }
            self?.isExpanding = false
        }
    }
}

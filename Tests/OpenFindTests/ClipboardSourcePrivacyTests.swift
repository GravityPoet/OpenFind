import AppKit
import Foundation
import Testing
@testable import OpenFind

@MainActor
@Suite("Clipboard Source Privacy Tests")
struct ClipboardSourcePrivacyTests {
    @Test func pendingCopyIsAttributedBeforeApplicationSwitch() throws {
        let suite = "OpenFindTests.ClipboardSourceSwitch.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let pasteboard = NSPasteboard(name: .init("OpenFindTests.\(UUID())"))
        let store = ClipboardHistoryStore(
            defaults: defaults,
            persistence: SourcePrivacyMemoryPersistence(),
            pasteboard: pasteboard
        )
        let passwords = ClipboardSourceApplication(
            bundleIdentifier: "com.example.Passwords",
            localizedName: "Passwords",
            identifiers: ["Passwords"]
        )
        let editor = ClipboardSourceApplication(
            bundleIdentifier: "com.example.Editor",
            localizedName: "Editor",
            identifiers: ["Editor"]
        )
        let sourceProvider = SourcePrivacyApplicationProvider(passwords)
        let monitor = ClipboardMonitor(
            store: store,
            pasteboard: pasteboard,
            activationNotificationCenter: NotificationCenter(),
            sourceApplicationProvider: { sourceProvider.application }
        )
        defer { monitor.stop() }
        store.setIgnoredBundleIdentifiers(["com.example.Passwords"])
        monitor.start(interval: 5)

        pasteboard.clearContents()
        #expect(pasteboard.setString("secret", forType: .string))
        sourceProvider.application = editor
        monitor.applicationDidActivate(editor)

        #expect(store.entries.isEmpty)

        pasteboard.clearContents()
        #expect(pasteboard.setString("ordinary", forType: .string))
        monitor.poll()

        #expect(store.entries.map { $0.previewText } == ["ordinary"])
        #expect(store.entries.first?.sourceBundleIdentifier == "com.example.Editor")
    }

    @Test func embeddedSourceCannotBypassPrivacyPoliciesAndIsPreserved() throws {
        let suite = "OpenFindTests.ClipboardEmbeddedSource.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let pasteboard = NSPasteboard(name: .init("OpenFindTests.\(UUID())"))
        let store = ClipboardHistoryStore(
            defaults: defaults,
            persistence: SourcePrivacyMemoryPersistence(),
            pasteboard: pasteboard
        )

        store.setIgnoredBundleIdentifiers(["com.example.Passwords"])
        write(
            "secret",
            sourceBundleIdentifier: "com.example.Passwords",
            to: pasteboard
        )
        #expect(!store.captureCurrentPasteboard(
            sourceBundleIdentifier: "com.example.Editor",
            sourceApplicationName: "Editor"
        ))

        store.setIgnoredBundleIdentifiers([])
        store.setAllowedBundleIdentifiers(["com.example.Editor"])
        store.setCaptureOnlyFromAllowedApplications(true)
        write(
            "spoofed",
            sourceBundleIdentifier: "com.example.Editor",
            to: pasteboard
        )
        #expect(!store.captureCurrentPasteboard(
            sourceBundleIdentifier: "com.example.Untrusted",
            sourceApplicationName: "Untrusted"
        ))

        store.setCaptureOnlyFromAllowedApplications(false)
        write(
            "preserved",
            sourceBundleIdentifier: "com.example.Original",
            to: pasteboard
        )
        #expect(store.captureCurrentPasteboard(
            sourceBundleIdentifier: "com.example.ClipboardManager",
            sourceApplicationName: "Clipboard Manager"
        ))
        let entry = try #require(store.entries.first)
        #expect(entry.sourceBundleIdentifier == "com.example.Original")
        #expect(entry.sourceApplicationName == nil)

        _ = try store.copy(entry)
        #expect(
            pasteboard.string(forType: .init(ClipboardHistoryStore.sourcePasteboardType))
                == "com.example.Original"
        )
    }

    private func write(
        _ text: String,
        sourceBundleIdentifier: String,
        to pasteboard: NSPasteboard
    ) {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setString(
            sourceBundleIdentifier,
            forType: .init(ClipboardHistoryStore.sourcePasteboardType)
        )
        pasteboard.clearContents()
        #expect(pasteboard.writeObjects([item]))
    }
}

private final class SourcePrivacyMemoryPersistence: ClipboardHistoryPersisting {
    private var entries: [ClipboardEntry] = []

    func load() throws -> [ClipboardEntry] {
        entries
    }

    func save(_ entries: [ClipboardEntry]) throws {
        self.entries = entries
    }

    func remove() throws {
        entries = []
    }
}

@MainActor
private final class SourcePrivacyApplicationProvider {
    var application: ClipboardSourceApplication

    init(_ application: ClipboardSourceApplication) {
        self.application = application
    }
}

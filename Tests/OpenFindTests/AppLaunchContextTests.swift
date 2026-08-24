import AppKit
import Testing
@testable import OpenFind

@MainActor
@Suite("App Launch Context Tests", .serialized)
struct AppLaunchContextTests {
    @Test func completedFirstLaunchStaysInTheMenuBarWithoutCreatingTheMainWindow() {
        let application = NSApplication.shared
        let existingWindows = Set(application.windows.map(ObjectIdentifier.init))
        let context = makeContext(shouldPresentFirstRunGuide: false)
        let delegate = context.delegate
        var appliedPolicies: [NSApplication.ActivationPolicy] = []
        delegate.activationPolicySetter = { policy in
            appliedPolicies.append(policy)
            return true
        }
        defer {
            closeTestWindows(application, excluding: existingWindows)
        }

        delegate.presentInitialInterface()

        let newMainWindow = application.windows.first {
            !existingWindows.contains(ObjectIdentifier($0))
                && $0.identifier?.rawValue == "OpenFind.main"
                && $0.isVisible
        }
        #expect(newMainWindow == nil)
        #expect(appliedPolicies.last == .accessory)
        #expect(context.persistence.loadCount == 1)
    }

    @Test func firstLaunchOpensTheMainWindowForTheWelcomeGuide() {
        let application = NSApplication.shared
        let existingWindows = Set(application.windows.map(ObjectIdentifier.init))
        let context = makeContext(shouldPresentFirstRunGuide: true)
        let delegate = context.delegate
        defer { closeTestWindows(application, excluding: existingWindows) }

        delegate.presentInitialInterface()

        let newMainWindow = application.windows.first {
            !existingWindows.contains(ObjectIdentifier($0))
                && $0.identifier?.rawValue == "OpenFind.main"
        }
        #expect(newMainWindow != nil)
        newMainWindow?.orderOut(nil)
    }

    @Test func primaryWindowStaysOutOfTheDockWhileVisible() throws {
        let application = NSApplication.shared
        let existingWindows = Set(application.windows.map(ObjectIdentifier.init))
        let context = makeContext(shouldPresentFirstRunGuide: false)
        let delegate = context.delegate
        var appliedPolicies: [NSApplication.ActivationPolicy] = []
        delegate.activationPolicySetter = { policy in
            appliedPolicies.append(policy)
            return true
        }
        defer {
            closeTestWindows(application, excluding: existingWindows)
        }

        delegate.showOpenFindWindow(nil)

        let window = try #require(application.windows.first {
            $0.identifier?.rawValue == "OpenFind.main" && $0.isVisible
        })
        #expect(window.isVisible)
        #expect(appliedPolicies.last == .accessory)

        #expect(!delegate.windowShouldClose(window))
        #expect(!window.isVisible)
        #expect(appliedPolicies.last == .accessory)
        #expect(context.persistence.loadCount == 1)
    }

    @Test func menuBarAndSettingsStaySearchColdUntilTheMainWindowOpens() throws {
        let application = NSApplication.shared
        let existingWindows = Set(application.windows.map(ObjectIdentifier.init))
        let context = makeContext(shouldPresentFirstRunGuide: false)
        let delegate = context.delegate
        defer { closeTestWindows(application, excluding: existingWindows) }

        delegate.presentInitialInterface()
        #expect(!delegate.viewModel.isIndexLifecycleStarted)

        delegate.showSettingsWindow(nil)
        #expect(!delegate.viewModel.isIndexLifecycleStarted)
        let settings = try #require(application.windows.first {
            $0.identifier?.rawValue == "OpenFind.settings" && $0.isVisible
        })
        #expect(!delegate.windowShouldClose(settings))

        delegate.showOpenFindWindow(nil)
        #expect(delegate.viewModel.isIndexLifecycleStarted)
    }

    @Test func openingThePrimaryWindowResumesClipboardPayloadResidence() throws {
        let application = NSApplication.shared
        let existingWindows = Set(application.windows.map(ObjectIdentifier.init))
        let context = makeContext(shouldPresentFirstRunGuide: false)
        let delegate = context.delegate
        defer { closeTestWindows(application, excluding: existingWindows) }

        delegate.clipboardStore.hibernatePayloadsForBackground()
        #expect(delegate.clipboardStore.isClipboardBackgroundResident)

        delegate.showOpenFindWindow(nil)
        #expect(!delegate.clipboardStore.isClipboardBackgroundResident)
        #expect(delegate.clipboardStore.ingest(
            representations: ["public.utf8-plain-text": Data("foreground clip".utf8)],
            previewText: "foreground clip",
            kind: .text
        ))
        #expect(delegate.clipboardStore.entries.first?.hasResidentPayload == true)
    }

    private func closeTestWindows(
        _ application: NSApplication,
        excluding existingWindows: Set<ObjectIdentifier>
    ) {
        application.windows
            .filter { !existingWindows.contains(ObjectIdentifier($0)) }
            .forEach { window in
                window.delegate = nil
                window.close()
            }
    }

    private func makeContext(shouldPresentFirstRunGuide: Bool) -> AppLaunchTestContext {
        let suiteName = "OpenFindTests.AppLaunchContext"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(
            !shouldPresentFirstRunGuide,
            forKey: FirstRunGuideStore.completionKey
        )
        let persistence = AppLaunchMemoryPersistence()
        let clipboardStore = ClipboardHistoryStore(
            defaults: defaults,
            persistence: persistence,
            pasteboard: NSPasteboard(name: .init(suiteName))
        )
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenFind-AppLaunch-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        let cacheURL = temporaryDirectory.appendingPathComponent("search-index.bin")
        let viewModel = SearchViewModel(
            indexStore: SearchIndexStore(persistenceURL: cacheURL),
            startIndexing: false,
            initialOptions: SearchOptions(),
            initialScopes: [temporaryDirectory],
            initialRecentSearches: [],
            initialFullDiskAccess: false
        )
        return AppLaunchTestContext(
            delegate: AppDelegate(
                viewModel: viewModel,
                clipboardStore: clipboardStore,
                defaults: defaults,
                launchAtLoginService: AppLaunchLoginService()
            ),
            persistence: persistence,
            defaults: defaults,
            suiteName: suiteName,
            temporaryDirectory: temporaryDirectory
        )
    }
}

private final class AppLaunchMemoryPersistence: ClipboardHistoryPersisting {
    private(set) var loadCount = 0

    func load() throws -> [ClipboardEntry] {
        loadCount += 1
        return []
    }

    func save(_ entries: [ClipboardEntry]) throws {}
    func remove() throws {}
}

@MainActor
private final class AppLaunchLoginService: LaunchAtLoginServicing {
    private(set) var status: LaunchAtLoginStatus = .disabled

    func register() throws { status = .enabled }
    func unregister() throws { status = .disabled }
    func openSystemSettings() {}
}

private final class AppLaunchTestContext {
    let delegate: AppDelegate
    let persistence: AppLaunchMemoryPersistence
    private let defaults: UserDefaults
    private let suiteName: String
    private let temporaryDirectory: URL

    init(
        delegate: AppDelegate,
        persistence: AppLaunchMemoryPersistence,
        defaults: UserDefaults,
        suiteName: String,
        temporaryDirectory: URL
    ) {
        self.delegate = delegate
        self.persistence = persistence
        self.defaults = defaults
        self.suiteName = suiteName
        self.temporaryDirectory = temporaryDirectory
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }
}

import AppIntents
import Foundation

struct ClipboardItemEntity: AppEntity, Identifiable, Sendable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Clipboard Item",
        numericFormat: "\(placeholder: .int) Clipboard Items"
    )
    static let defaultQuery = ClipboardItemEntityQuery()

    let id: UUID
    let title: String
    let subtitle: String
    let isPinned: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(subtitle)",
            image: .init(systemName: isPinned ? "pin.fill" : "clipboard")
        )
    }

    init(entry: ClipboardEntry) {
        id = entry.id
        title = entry.kind.localizedTitle
        subtitle = [
            entry.sourceApplicationName,
            entry.createdAt.formatted(date: .abbreviated, time: .shortened),
        ]
            .compactMap { $0 }
            .joined(separator: " · ")
        isPinned = entry.isPinned
    }
}

struct ClipboardItemEntityQuery: EntityQuery, Sendable {
    init() {}

    func entities(for identifiers: [UUID]) async throws -> [ClipboardItemEntity] {
        let requested = Set(identifiers)
        return await MainActor.run {
            (AppDelegate.shared?.clipboardStore.entries ?? [])
                .filter { requested.contains($0.id) }
                .map(ClipboardItemEntity.init)
        }
    }

    func suggestedEntities() async throws -> [ClipboardItemEntity] {
        await MainActor.run {
            Array((AppDelegate.shared?.clipboardStore.entries ?? [])
                .sorted { $0.createdAt > $1.createdAt }
                .prefix(30))
                .map(ClipboardItemEntity.init)
        }
    }
}

struct GetRecentClipboardItemsIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Recent Clipboard Items"
    static let description = IntentDescription(
        "Returns recent clipboard item references without returning their full contents."
    )

    @Parameter(title: "Maximum Items", default: 10, inclusiveRange: (1, 50))
    var limit: Int

    func perform() async throws -> some IntentResult & ReturnsValue<[ClipboardItemEntity]> {
        let entities = await MainActor.run {
            Array((AppDelegate.shared?.clipboardStore.entries ?? [])
                .sorted { $0.createdAt > $1.createdAt }
                .prefix(limit))
                .map(ClipboardItemEntity.init)
        }
        return .result(value: entities)
    }
}

struct GetClipboardItemTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Clipboard Item Text"
    static let description = IntentDescription(
        "Returns the full plain-text contents of the explicitly selected clipboard item."
    )
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Clipboard Item")
    var item: ClipboardItemEntity

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let text = try await MainActor.run { () throws -> String in
            guard let store = AppDelegate.shared?.clipboardStore,
                  let entry = store.entries.first(where: { $0.id == item.id }) else {
                throw ClipboardHistoryError.entryNotFound
            }
            guard let text = store.plainText(for: entry) else {
                throw ClipboardHistoryError.unsupportedContent
            }
            return text
        }
        return .result(value: text)
    }
}

struct CopyClipboardItemIntent: AppIntent {
    static let title: LocalizedStringResource = "Copy Clipboard Item"
    static let description = IntentDescription(
        "Copies the selected OpenFind history item back to the system clipboard."
    )
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Clipboard Item")
    var item: ClipboardItemEntity

    @Parameter(title: "Plain Text Only", default: false)
    var plainTextOnly: Bool

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await MainActor.run {
            guard let store = AppDelegate.shared?.clipboardStore,
                  let entry = store.entries.first(where: { $0.id == item.id }) else {
                throw ClipboardHistoryError.entryNotFound
            }
            try store.copy(entry, plainTextOnly: plainTextOnly)
        }
        return .result(dialog: "Copied to the clipboard.")
    }
}

struct DeleteClipboardItemIntent: AppIntent {
    static let title: LocalizedStringResource = "Delete Clipboard Item"
    static let description = IntentDescription(
        "Permanently deletes the explicitly selected item from OpenFind history."
    )
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Clipboard Item")
    var item: ClipboardItemEntity

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await MainActor.run {
            guard let store = AppDelegate.shared?.clipboardStore,
                  let entry = store.entries.first(where: { $0.id == item.id }) else {
                throw ClipboardHistoryError.entryNotFound
            }
            store.delete(entry)
        }
        return .result(dialog: "Clipboard item deleted.")
    }
}

struct ClearClipboardHistoryIntent: AppIntent {
    static let title: LocalizedStringResource = "Clear Clipboard History"
    static let description = IntentDescription(
        "Clears clipboard history while preserving reusable snippets unless requested otherwise."
    )
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Also Delete Reusable Snippets", default: false)
    var includeReusableSnippets: Bool

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await MainActor.run {
            guard let store = AppDelegate.shared?.clipboardStore else { return }
            includeReusableSnippets ? store.clearAll() : store.clearUnpinned()
        }
        return .result(dialog: includeReusableSnippets
            ? "Clipboard history and reusable snippets cleared."
            : "Clipboard history cleared; reusable snippets were preserved.")
    }
}

struct CreateClipboardSnippetIntent: AppIntent {
    static let title: LocalizedStringResource = "Create Reusable Snippet"
    static let description = IntentDescription(
        "Creates an encrypted reusable text snippet with an optional collection and keyword."
    )
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Name")
    var name: String

    @Parameter(title: "Content")
    var content: String

    @Parameter(title: "Keyword")
    var keyword: String?

    @Parameter(title: "Collection")
    var collection: String?

    @Parameter(title: "Expand Automatically", default: false)
    var expandsAutomatically: Bool

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await MainActor.run {
            guard let store = AppDelegate.shared?.clipboardStore else {
                throw ClipboardHistoryError.persistenceUnavailable
            }
            _ = try store.createSnippet(
                name: name,
                content: content,
                keyword: keyword,
                collection: collection,
                expandsAutomatically: expandsAutomatically
            )
        }
        return .result(dialog: "Reusable snippet created.")
    }
}

struct ShowClipboardHistoryIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Clipboard History"
    static let description = IntentDescription("Opens the centered OpenFind clipboard panel.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            AppDelegate.shared?.clipboard.showWindow()
        }
        return .result()
    }
}

struct OpenFindClipboardShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ShowClipboardHistoryIntent(),
            phrases: [
                "Show clipboard history in \(.applicationName)",
                "Open \(.applicationName) clipboard",
            ],
            shortTitle: "Show Clipboard",
            systemImageName: "clipboard"
        )
        AppShortcut(
            intent: GetRecentClipboardItemsIntent(),
            phrases: ["Get recent clipboard items from \(.applicationName)"],
            shortTitle: "Recent Clipboard Items",
            systemImageName: "clock.arrow.circlepath"
        )
        AppShortcut(
            intent: CreateClipboardSnippetIntent(),
            phrases: ["Create a reusable snippet in \(.applicationName)"],
            shortTitle: "Create Snippet",
            systemImageName: "text.badge.plus"
        )
    }

    static let shortcutTileColor: ShortcutTileColor = .blue
}

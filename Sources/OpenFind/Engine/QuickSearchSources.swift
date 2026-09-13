import Foundation

/// Shared bounded-lifetime source snapshots keep disk/Contacts reads off the
/// main actor. Bookmarks and authorized contacts also participate in defaults.
actor QuickSearchSources {
    static let shared = QuickSearchSources()
    private var bookmarks: BookmarkSearchIndex.Snapshot?
    private var bookmarkDate = Date.distantPast
    private var contacts: [QuickContact] = []
    private var contactDate = Date.distantPast

    nonisolated static func results(_ command: QuickSearchCommand, limit: Int,
                                   application: ApplicationSearchResult?) async -> QuickSearchSourceResponse {
        await shared.search(command, limit: limit, application: application)
    }

    func search(_ command: QuickSearchCommand, limit: Int,
                application: ApplicationSearchResult?) -> QuickSearchSourceResponse {
        if ProcessInfo.processInfo.environment["OPENFIND_TEST_MODE"] == "1" { return .init() }
        switch command.mode {
        case .path:
            return QuickPathSearch.search(command.term, limit: limit, includeHidden: Preferences.loadOptions().includeHidden)
        case .web: return .init(items: WebSearchIndex.results(for: command.term))
        case .recent: return RecentDocumentsSearch.search(command.term, application: application, limit: limit)
        case .bookmarks: return bookmarkSearch(command.term, limit: limit)
        case .contacts: return contactSearch(command.term, limit: limit, explicit: true)
        case .combined:
            let bookmarks = bookmarkSearch(command.term, limit: limit)
            let contacts = contactSearch(command.term, limit: limit, explicit: false)
            var response = QuickSearchSourceResponse.page(bookmarks.items + contacts.items, limit: limit)
            response.hasMore = response.hasMore || bookmarks.hasMore || contacts.hasMore
            return response
        default: return .init()
        }
    }

    func releaseSnapshots() {
        bookmarks = nil
        bookmarkDate = .distantPast
        contacts = []
        contactDate = .distantPast
    }

    private func bookmarkSearch(_ query: String, limit: Int) -> QuickSearchSourceResponse {
        if bookmarks == nil || Date().timeIntervalSince(bookmarkDate) > 15 {
            bookmarks = BookmarkSearchIndex.discover()
            bookmarkDate = Date()
        }
        return BookmarkSearchIndex.search(query, snapshot: bookmarks ?? .init(), limit: limit)
    }

    private func contactSearch(_ query: String, limit: Int, explicit: Bool) -> QuickSearchSourceResponse {
        guard ContactSearchIndex.isAuthorized else {
            contacts = []
            contactDate = .distantPast
            return explicit ? ContactSearchIndex.accessResponse() : .init()
        }
        do {
            if Date().timeIntervalSince(contactDate) > 15 {
                let discovered = try ContactSearchIndex.discover()
                try Task.checkCancellation()
                contacts = discovered
                contactDate = Date()
            }
            return ContactSearchIndex.search(query, contacts: contacts, limit: limit)
        } catch { return .init(message: explicit ? L("Contacts Unavailable") : nil) }
    }
}

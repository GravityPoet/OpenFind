import Foundation

enum QuickSearchItemAction: Hashable, Sendable {
    case open
    case reveal
    case fullSearch(String)
    case requestContactsAccess
    case showContact(QuickContact)
    case recentDocuments(ApplicationSearchResult)
    case openWithApplication(URL)
    case copyText(String)
    case system(QuickSystemAction)
    case terminal(String)
}

struct QuickSearchItem: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case application, file, folder, setting, bookmark, contact, web, command
    }
    let url: URL
    let name: String
    let location: String
    let kind: Kind
    let action: QuickSearchItemAction
    let application: ApplicationSearchResult?

    var id: URL { url }
    var isApplication: Bool { kind == .application }
    var isSystemSetting: Bool { kind == .setting }
    var isDirectory: Bool { kind == .folder }
    var symbolName: String {
        switch kind {
        case .application: return "app"
        case .file: return "doc"
        case .folder: return "folder"
        case .setting: return "gearshape"
        case .bookmark: return "bookmark"
        case .contact: return "person.crop.circle"
        case .web: return "globe"
        case .command: return "arrow.forward.circle"
        }
    }

    init(systemSetting: ApplicationSearchResult) {
        self.init(url: systemSetting.url, name: systemSetting.name, location: L("System Settings"), kind: .setting)
    }

    init(application: ApplicationSearchResult, action: QuickSearchItemAction = .open) {
        self.init(url: application.url, name: application.name,
                  location: application.url.deletingLastPathComponent().path,
                  kind: .application, action: action, application: application)
    }

    init(file: SearchResult, action: QuickSearchItemAction = .open) {
        self.init(url: file.url, name: file.name, location: file.locationPath,
                  kind: file.isDirectory && !file.isPackage ? .folder : .file, action: action)
    }

    init(url: URL, name: String, location: String, kind: Kind = .file,
         action: QuickSearchItemAction = .open, application: ApplicationSearchResult? = nil) {
        self.url = url
        self.name = name
        self.location = location
        self.kind = kind
        self.action = action
        self.application = application
    }
}

struct QuickSearchSourceResponse: Sendable {
    var items: [QuickSearchItem] = []
    var hasMore = false
    var message: String?

    static func page(_ items: [QuickSearchItem], limit: Int, message: String? = nil) -> Self {
        .init(items: Array(items.prefix(limit)), hasMore: items.count > limit, message: message)
    }
}

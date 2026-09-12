import Foundation

/// One row in the lightweight launcher. Applications are kept ahead of file
/// and folder matches so the common Alfred use case remains one Return away.
struct QuickSearchItem: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let location: String
    let isApplication: Bool

    var id: URL { url }
    var isSystemSetting: Bool { url.scheme == "x-apple.systempreferences" }

    init(systemSetting: ApplicationSearchResult) {
        url = systemSetting.url
        name = systemSetting.name
        location = L("System Settings")
        isApplication = false
    }

    init(application: ApplicationSearchResult) {
        url = application.url
        name = application.name
        location = application.url.deletingLastPathComponent().path
        isApplication = true
    }

    init(file: SearchResult) {
        url = file.url
        name = file.name
        location = file.locationPath
        isApplication = false
    }
}

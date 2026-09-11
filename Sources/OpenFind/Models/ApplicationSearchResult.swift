import Foundation

/// A launchable application discovered from the macOS application locations.
/// The display row only keeps the metadata needed by the quick launcher; icons
/// remain lazy so opening the panel never has to decode every application icon.
struct ApplicationSearchResult: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let bundleIdentifier: String?
    let searchNames: [ApplicationSearchName]

    var id: URL { url }

    init(url: URL, name: String, bundleIdentifier: String?, aliases: [String] = []) {
        self.url = url
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        searchNames = Array(Set([name, url.deletingPathExtension().lastPathComponent] + aliases))
            .filter { !$0.isEmpty }
            .sorted()
            .map(ApplicationSearchName.init)
    }
}

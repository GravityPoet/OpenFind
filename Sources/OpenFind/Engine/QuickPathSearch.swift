import Foundation

/// Directory enumeration runs off the main actor. It never changes the user's
/// persistent search scope or starts a recursive whole-disk scan.
enum QuickPathSearch {
    static func search(_ rawPath: String, limit: Int = 50, includeHidden: Bool = true) -> QuickSearchSourceResponse {
        let expanded = (rawPath as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return .init(message: L("Path Unavailable")) }
        var directory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: expanded, isDirectory: &directory)
        let root = exists && directory.boolValue ? expanded : (expanded as NSString).deletingLastPathComponent
        let pattern = exists && directory.boolValue ? "" : (expanded as NSString).lastPathComponent
        if exists && !directory.boolValue {
            let url = URL(fileURLWithPath: expanded)
            let values = try? url.resourceValues(forKeys: [.localizedNameKey])
            return .init(items: [.init(url: url, name: values?.localizedName ?? url.lastPathComponent,
                                       location: root, kind: .file)])
        }
        let hasWildcard = pattern.contains("*") || pattern.contains("?")
        let matcher = hasWildcard ? try? Matcher(options: .init(query: pattern, matchMode: .wildcard)) : nil
        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .isHiddenKey, .localizedNameKey],
                options: includeHidden ? [] : [.skipsHiddenFiles]
            )
            let items = urls.compactMap { url -> QuickSearchItem? in
                let matches = pattern.isEmpty || (hasWildcard ? matcher?.matches(url.lastPathComponent) == true
                    : url.lastPathComponent.range(of: pattern, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil)
                guard matches else { return nil }
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .localizedNameKey])
                let folder = values?.isDirectory == true && values?.isPackage != true
                return .init(url: url, name: values?.localizedName ?? url.lastPathComponent,
                             location: root, kind: folder ? .folder : .file)
            }.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            return .page(items, limit: limit, message: items.isEmpty ? L("No Path Matches") : nil)
        } catch {
            return .init(message: L("Path Unavailable"))
        }
    }

    static func parent(of rawPath: String) -> String {
        let expanded = (rawPath as NSString).expandingTildeInPath
        let parent = (URL(fileURLWithPath: expanded).standardizedFileURL.path as NSString).deletingLastPathComponent
        return parent == "/" ? "/" : parent + "/"
    }
}

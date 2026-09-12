import Foundation

/// Reads the installed Settings-extension metadata instead of maintaining a
/// product-owned list that would go stale with every macOS release. Search-term
/// resources are local and are never sent outside the process.
actor SystemSettingsSearchIndex {
    static let shared = SystemSettingsSearchIndex()

    private var cached: [ApplicationSearchResult]?
    private var refreshTask: Task<[ApplicationSearchResult], Never>?

    func results(for query: String) async -> [ApplicationSearchResult] {
        if cached == nil {
            if refreshTask == nil {
                refreshTask = Task.detached(priority: .utility) { Self.discover() }
            }
            cached = await refreshTask?.value ?? []
            refreshTask = nil
        }
        return ApplicationSearchMatcher.rank(query, in: cached ?? [])
    }

    nonisolated static func discover(
        root: URL = URL(fileURLWithPath: "/System/Library/ExtensionKit/Extensions"),
        language: String = AppLocalization.identifier == "zh-Hans" ? "zh_CN" : "en"
    ) -> [ApplicationSearchResult] {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        return names.compactMap { extensionURL in
            let infoURL = extensionURL.appendingPathComponent("Contents/Info.plist")
            guard let info = NSDictionary(contentsOf: infoURL) as? [String: Any],
                  let attributes = info["EXAppExtensionAttributes"] as? [String: Any],
                  attributes["EXExtensionPointIdentifier"] as? String
                    == "com.apple.Settings.extension.ui",
                  let settings = attributes["SettingsExtensionAttributes"] as? [String: Any],
                  settings["allowsXAppleSystemPreferencesURLScheme"] as? Bool == true,
                  let identifier = info["CFBundleIdentifier"] as? String,
                  identifier.hasPrefix("com.apple."),
                  let url = URL(string: "x-apple.systempreferences:\(identifier)") else {
                return nil
            }
            let localized = localizedInfo(
                extensionURL: extensionURL,
                language: language,
                fallback: info
            )
            let displayName = localized["CFBundleDisplayName"] as? String
                ?? localized["CFBundleName"] as? String
                ?? info["CFBundleDisplayName"] as? String
                ?? info["CFBundleName"] as? String
                ?? identifier
            var aliases = [info["CFBundleDisplayName"] as? String, info["CFBundleName"] as? String]
                .compactMap { $0 }
            for aliasLanguage in ["en", "zh_CN"] {
                let translations = localizedInfo(extensionURL: extensionURL, language: aliasLanguage, fallback: info)
                aliases += [translations["CFBundleDisplayName"], translations["CFBundleName"]]
                    .compactMap { $0 as? String }
            }
            // Wi-Fi contains a non-breaking hyphen in Apple's display name.
            aliases += aliases.map { $0.replacingOccurrences(of: "‑", with: "-").replacingOccurrences(of: "-", with: "") }
            if let termsFile = settings["searchTermsFileName"] as? String {
                for aliasLanguage in ["en", "zh_CN"] {
                    aliases += searchTerms(extensionURL: extensionURL, fileName: termsFile, language: aliasLanguage)
                }
            }
            return ApplicationSearchResult(
                url: url,
                name: displayName,
                bundleIdentifier: identifier,
                aliases: aliases
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private nonisolated static func localizedInfo(
        extensionURL: URL, language: String, fallback: [String: Any]
    ) -> [String: Any] {
        let path = extensionURL.appendingPathComponent(
            "Contents/Resources/\(language).lproj/InfoPlist.strings"
        )
        if let strings = NSDictionary(contentsOf: path) as? [String: Any] { return strings }
        let tableURL = extensionURL.appendingPathComponent("Contents/Resources/InfoPlist.loctable")
        let table = NSDictionary(contentsOf: tableURL) as? [String: Any]
        return table?[language] as? [String: Any] ?? table?["en"] as? [String: Any] ?? fallback
    }

    private nonisolated static func searchTerms(
        extensionURL: URL, fileName: String, language: String
    ) -> [String] {
        let path = extensionURL.appendingPathComponent(
            "Contents/Resources/\(language).lproj/\(fileName).searchTerms"
        )
        guard let data = try? Data(contentsOf: path),
              let object = try? PropertyListSerialization.propertyList(
                  from: data, format: nil
              ) else { return [] }
        return collectTerms(object)
    }

    private nonisolated static func collectTerms(_ value: Any) -> [String] {
        if let values = value as? [Any] { return values.flatMap(collectTerms) }
        guard let dictionary = value as? [String: Any] else { return [] }
        var output: [String] = []
        if let title = dictionary["title"] as? String { output.append(title) }
        if let index = dictionary["index"] as? String {
            output += index.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        for (key, nested) in dictionary where key != "title" && key != "index" && key != "comments" {
            output.append(contentsOf: collectTerms(nested))
        }
        return output
    }
}

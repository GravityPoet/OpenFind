import Foundation

@MainActor
final class ConfigurationTransferStore {
    let defaults: UserDefaults
    let clipboard: ClipboardHistoryStore
    let recoveryURL: URL
    let domainName: String
    var reload: () -> Void = {}
    var canApply: () -> Bool = { true }

    init(defaults: UserDefaults, clipboard: ClipboardHistoryStore, recoveryURL: URL,
         domainName: String = "com.openfind.app") {
        self.defaults = defaults
        self.clipboard = clipboard
        self.recoveryURL = recoveryURL
        self.domainName = domainName
    }

    func snapshot() throws -> ConfigurationArchive {
        var values: [String: Data] = [:]
        for key in ConfigurationPreferenceKeys.all {
            if var value = defaults.object(forKey: key) {
                if key == "OpenFind.clipboardPreferencesV3", let data = value as? Data {
                    value = try ConfigurationPreferenceKeys.portableClipboardData(data)
                }
                values[key] = try PropertyListSerialization.data(fromPropertyList: [value], format: .binary, options: 0)
            }
        }
        return ConfigurationArchive(preferences: values, snippets: try clipboard.configurationSnippets())
    }

    func validate(_ archive: ConfigurationArchive) throws -> [String: Any] {
        guard archive.format == "OpenFind Configuration", archive.version == 1,
              archive.preferences.keys.allSatisfy(ConfigurationPreferenceKeys.all.contains),
              archive.snippets.count <= ClipboardHistoryStore.maximumSnippetCount else {
            throw ConfigurationError.invalidPreferences
        }
        var values: [String: Any] = [:]
        for (key, encoded) in archive.preferences {
            guard encoded.count <= ConfigurationFile.maximumBytes,
                  let array = try PropertyListSerialization.propertyList(from: encoded, format: nil) as? [Any],
                  array.count == 1 else { throw ConfigurationError.invalidPreferences }
            values[key] = array[0]
        }
        try ConfigurationPreferenceKeys.validate(values)
        _ = try clipboard.validatedConfigurationSnippets(archive.snippets)
        return values
    }

    func apply(_ archive: ConfigurationArchive, preservingRecovery: Bool = false) async throws {
        var values = try validate(archive)
        guard canApply(), clipboard.isPersistenceEnabled, !clipboard.requiresPersistenceMigration,
              !clipboard.isPersistenceDegraded else { throw ConfigurationError.unavailable }
        let before = try snapshot()
        let canonicalArchive = ConfigurationArchive(
            preferences: archive.preferences,
            snippets: try clipboard.validatedConfigurationSnippets(archive.snippets)
                .sorted { $0.id.uuidString < $1.id.uuidString }
        )
        guard before != canonicalArchive else { return }
        if !preservingRecovery {
            try FileManager.default.createDirectory(at: recoveryURL.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            let previous = try await ConfigurationFile.read(recoveryURL)
            try await ConfigurationFile.write(before.encoded(), to: recoveryURL, replacing: previous)
        }
        // Configuration is applied on the main actor without suspension after
        // the backup. Recheck after IO so a concurrent local edit is preserved.
        guard canApply(), try snapshot() == before else { throw ConfigurationError.conflict }
        let oldDomain = defaults.persistentDomain(forName: domainName) ?? [:]
        // Pause/ignore-next and the display number belong to the destination.
        // User-selected expansion and merge behavior remains portable.
        var importedClipboard = ClipboardPreferences()
        if let data = values["OpenFind.clipboardPreferencesV3"] as? Data {
            importedClipboard = try JSONDecoder().decode(ClipboardPreferences.self, from: data)
        }
        importedClipboard.capturePaused = clipboard.preferences.capturePaused
        importedClipboard.ignoreOnlyNextCapture = clipboard.preferences.ignoreOnlyNextCapture
        importedClipboard.popupScreen = clipboard.preferences.popupScreen
        values["OpenFind.clipboardPreferencesV3"] = try JSONEncoder().encode(importedClipboard)
        try clipboard.replaceConfigurationSnippets(canonicalArchive.snippets)
        var domain = oldDomain
        for key in ConfigurationPreferenceKeys.all {
            domain[key] = values[key]
        }
        // Imports are already in the current schema. Older default migrations
        // must never override explicitly imported values on another Mac.
        domain["search.comprehensiveResultsDefaultV1"] = true
        domain["search.comprehensiveIndexDefaultV1"] = true
        domain["search.comprehensiveContentSizeDefaultV2"] = true
        domain["OpenFind.globalHotKeyDefaultV2"] = true
        domain["OpenFind.clipboardDefaultIgnoredAppsSeedVersionV1"] = 2
        domain["OpenFind.clipboardCenteredPopupMigrationVersionV1"] = 1
        defaults.setPersistentDomain(domain, forName: domainName)
        guard defaults.synchronize() else {
            defaults.setPersistentDomain(oldDomain, forName: domainName)
            try clipboard.replaceConfigurationSnippets(before.snippets)
            throw ConfigurationError.saveFailed
        }
        clipboard.preferences = importedClipboard
        reload()
    }
}

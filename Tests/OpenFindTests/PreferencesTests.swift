import Testing
import Foundation
import Carbon
@testable import OpenFind

@Suite("Preferences Tests", .serialized)
struct PreferencesTests {
    
    @Test func testPreferencesSaveAndLoad() {
        let keys = [
            "search.target",
            "search.matchMode",
            "search.caseSensitive",
            "search.includeHidden",
            "search.includePackages",
            "search.comprehensiveResultsDefaultV1",
            "search.deepIndex",
            "search.comprehensiveIndexDefaultV1",
            "search.maxContentFileSize",
            "search.comprehensiveContentSizeDefaultV2",
            "search.maxContentIndexBytes",
            "search.recent"
        ]
        
        var backup: [String: Any?] = [:]
        for key in keys {
            backup[key] = UserDefaults.standard.object(forKey: key)
        }
        
        defer {
            for (key, value) in backup {
                if let val = value {
                    UserDefaults.standard.set(val, forKey: key)
                } else {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
        }
        
        var testOptions = SearchOptions()
        testOptions.query = "should_not_persist"
        testOptions.target = .content
        testOptions.matchMode = .regex
        testOptions.caseSensitive = true
        testOptions.includeHidden = true
        testOptions.includePackages = true
        testOptions.maxContentFileSize = 50 * 1024 * 1024
        testOptions.maxContentIndexBytes = 8 * 1024 * 1024 * 1024
        
        Preferences.saveOptions(testOptions)
        
        let loaded = Preferences.loadOptions()
        
        #expect(loaded.target == .content)
        #expect(loaded.matchMode == .regex)
        #expect(loaded.caseSensitive == true)
        #expect(loaded.includeHidden == true)
        #expect(loaded.includePackages == true)
        #expect(loaded.deepIndex == true)
        #expect(loaded.maxContentFileSize == 50 * 1024 * 1024)
        #expect(loaded.maxContentIndexBytes == 8 * 1024 * 1024 * 1024)
        #expect(loaded.query.isEmpty)
    }

    @Test func contentAccelerationCacheDefaultsToFourGigabytes() {
        let key = "search.maxContentIndexBytes"
        let backup = UserDefaults.standard.object(forKey: key)
        defer {
            if let backup {
                UserDefaults.standard.set(backup, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        UserDefaults.standard.removeObject(forKey: key)
        #expect(Preferences.loadOptions().maxContentIndexBytes == 4 * 1_024 * 1_024 * 1_024)
    }

    @Test func defaultsIncludeHiddenFiles() {
        let key = "search.includeHidden"
        let backup = UserDefaults.standard.object(forKey: key)

        defer {
            if let val = backup {
                UserDefaults.standard.set(val, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        UserDefaults.standard.removeObject(forKey: key)
        #expect(Preferences.loadOptions().includeHidden)
    }

    @Test func defaultsToComprehensiveIndexing() {
        let keys = ["search.deepIndex", "search.comprehensiveIndexDefaultV1"]
        let backup = Dictionary(uniqueKeysWithValues: keys.map { ($0, UserDefaults.standard.object(forKey: $0)) })

        defer {
            for (key, value) in backup {
                if let value {
                    UserDefaults.standard.set(value, forKey: key)
                } else {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
        }

        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        #expect(Preferences.loadOptions().deepIndex)
        #expect(UserDefaults.standard.bool(forKey: "search.comprehensiveIndexDefaultV1"))
    }

    @Test func defaultsToSearchingPackageContents() {
        let keys = ["search.includePackages", "search.comprehensiveResultsDefaultV1"]
        let backup = Dictionary(uniqueKeysWithValues: keys.map { ($0, UserDefaults.standard.object(forKey: $0)) })

        defer {
            for (key, value) in backup {
                if let value {
                    UserDefaults.standard.set(value, forKey: key)
                } else {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
        }

        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        #expect(Preferences.loadOptions().includePackages)
        #expect(UserDefaults.standard.bool(forKey: "search.comprehensiveResultsDefaultV1"))
    }

    @Test func contentSizeMigrationUpgradesOldDefaultButPreservesLaterChoice() {
        let keys = ["search.maxContentFileSize", "search.comprehensiveContentSizeDefaultV2"]
        let backup = Dictionary(uniqueKeysWithValues: keys.map { ($0, UserDefaults.standard.object(forKey: $0)) })

        defer {
            for (key, value) in backup {
                if let value {
                    UserDefaults.standard.set(value, forKey: key)
                } else {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
        }

        UserDefaults.standard.set(16 * 1_024 * 1_024, forKey: "search.maxContentFileSize")
        UserDefaults.standard.removeObject(forKey: "search.comprehensiveContentSizeDefaultV2")
        #expect(Preferences.loadOptions().maxContentFileSize == 100 * 1_024 * 1_024)
        #expect(UserDefaults.standard.bool(forKey: "search.comprehensiveContentSizeDefaultV2"))

        UserDefaults.standard.set(16 * 1_024 * 1_024, forKey: "search.maxContentFileSize")
        #expect(Preferences.loadOptions().maxContentFileSize == 16 * 1_024 * 1_024)
    }

    @Test func packageMigrationUpgradesOldDefaultButPreservesLaterOptOut() {
        let keys = ["search.includePackages", "search.comprehensiveResultsDefaultV1"]
        let backup = Dictionary(uniqueKeysWithValues: keys.map { ($0, UserDefaults.standard.object(forKey: $0)) })

        defer {
            for (key, value) in backup {
                if let value {
                    UserDefaults.standard.set(value, forKey: key)
                } else {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
        }

        UserDefaults.standard.set(false, forKey: "search.includePackages")
        UserDefaults.standard.removeObject(forKey: "search.comprehensiveResultsDefaultV1")
        #expect(Preferences.loadOptions().includePackages)

        UserDefaults.standard.set(false, forKey: "search.includePackages")
        #expect(!Preferences.loadOptions().includePackages)
    }
    
    @Test func testRecentSearches() {
        let key = "search.recent"
        let backup = UserDefaults.standard.object(forKey: key)
        
        defer {
            if let val = backup {
                UserDefaults.standard.set(val, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        
        Preferences.clearRecentSearches()
        #expect(Preferences.recentSearches.isEmpty)
        
        Preferences.addRecentSearch("swift")
        Preferences.addRecentSearch("apple ")
        Preferences.addRecentSearch("SWIFT")
        
        let list = Preferences.recentSearches
        #expect(list.count == 2)
        #expect(list[0] == "SWIFT")
        #expect(list[1] == "apple")
    }

    @MainActor
    @Test func globalHotKeyPreferencePersists() throws {
        let suiteName = "OpenFindTests.GlobalHotKey.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let enabledByDefault = GlobalHotKeyController(defaults: defaults)
        #expect(enabledByDefault.isEnabled)
        #expect(enabledByDefault.shortcut == .defaultValue)
        #expect(enabledByDefault.shortcut.displayText == "⌃⌥F")

        enabledByDefault.setEnabled(false)
        let customShortcut = GlobalShortcut(
            keyCode: UInt32(kVK_ANSI_K),
            modifiers: UInt32(cmdKey | optionKey),
            keyLabel: "K"
        )
        #expect(enabledByDefault.setShortcut(customShortcut))

        let reloaded = GlobalHotKeyController(defaults: defaults)
        #expect(!reloaded.isEnabled)
        #expect(reloaded.shortcut == customShortcut)

        let invalidShortcut = GlobalShortcut(
            keyCode: UInt32(kVK_ANSI_K),
            modifiers: UInt32(shiftKey),
            keyLabel: "K"
        )
        #expect(!reloaded.setShortcut(invalidShortcut))
        #expect(reloaded.shortcut == customShortcut)

        reloaded.resetShortcut()
        #expect(reloaded.shortcut == .defaultValue)

        defaults.set(-1, forKey: "OpenFind.globalHotKeyKeyCode")
        defaults.set(-1, forKey: "OpenFind.globalHotKeyModifiers")
        defaults.set(String(repeating: "K", count: 100), forKey: "OpenFind.globalHotKeyLabel")
        #expect(GlobalHotKeyController(defaults: defaults).shortcut == .defaultValue)

        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(Int(GlobalShortcut.legacyDefaultValue.keyCode), forKey: "OpenFind.globalHotKeyKeyCode")
        defaults.set(Int(GlobalShortcut.legacyDefaultValue.modifiers), forKey: "OpenFind.globalHotKeyModifiers")
        defaults.set(GlobalShortcut.legacyDefaultValue.keyLabel, forKey: "OpenFind.globalHotKeyLabel")
        let migrated = GlobalHotKeyController(defaults: defaults)
        #expect(migrated.shortcut == .defaultValue)

        #expect(migrated.setShortcut(.legacyDefaultValue))
        #expect(GlobalHotKeyController(defaults: defaults).shortcut == .legacyDefaultValue)
    }
}

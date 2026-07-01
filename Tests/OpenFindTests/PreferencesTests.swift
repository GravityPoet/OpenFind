import Testing
import Foundation
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
            "search.maxContentFileSize",
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
        
        Preferences.saveOptions(testOptions)
        
        let loaded = Preferences.loadOptions()
        
        #expect(loaded.target == .content)
        #expect(loaded.matchMode == .regex)
        #expect(loaded.caseSensitive == true)
        #expect(loaded.includeHidden == true)
        #expect(loaded.includePackages == true)
        #expect(loaded.maxContentFileSize == 50 * 1024 * 1024)
        #expect(loaded.query.isEmpty)
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
}

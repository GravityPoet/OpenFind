import Testing
import Foundation
@testable import OpenFind

@Suite("Matcher Tests")
struct MatcherTests {
    
    @Test func testEmptyQueryThrows() throws {
        var options = SearchOptions()
        options.query = ""
        options.matchMode = .substring
        
        #expect(throws: MatcherError.emptyQuery) {
            _ = try Matcher(options: options)
        }
    }
    
    @Test func testInvalidRegexThrows() throws {
        var options = SearchOptions()
        options.query = "[invalid"
        options.matchMode = .regex
        
        #expect(throws: Error.self) {
            _ = try Matcher(options: options)
        }
    }
    
    @Test func testSubstringMode() throws {
        var options = SearchOptions()
        options.query = "Swift"
        options.matchMode = .substring
        
        // Case-sensitive
        options.caseSensitive = true
        let matcherSensitive = try Matcher(options: options)
        #expect(matcherSensitive.matches("Swift is great"))
        #expect(!matcherSensitive.matches("swift is great"))
        
        // Case-insensitive
        options.caseSensitive = false
        let matcherInsensitive = try Matcher(options: options)
        #expect(matcherInsensitive.matches("Swift is great"))
        #expect(matcherInsensitive.matches("swift is great"))
        #expect(matcherInsensitive.matches("SWIFT"))
        #expect(!matcherInsensitive.matches("ObjC"))
    }
    
    @Test func testWholeWordMode() throws {
        var options = SearchOptions()
        options.query = "swift"
        options.matchMode = .wholeWord
        options.caseSensitive = false
        
        let matcher = try Matcher(options: options)
        #expect(matcher.matches("swift"))
        #expect(matcher.matches("swift developer"))
        #expect(matcher.matches("hello swift!"))
        #expect(matcher.matches("hello, swift, world"))
        #expect(!matcher.matches("swifty"))
        #expect(!matcher.matches("myswift"))
    }
    
    @Test func testWildcardMode() throws {
        var options = SearchOptions()
        options.matchMode = .wildcard
        options.caseSensitive = false
        
        // *.txt wildcard
        options.query = "*.txt"
        let matcher1 = try Matcher(options: options)
        #expect(matcher1.matches("hello.txt"))
        #expect(matcher1.matches("a.txt"))
        #expect(matcher1.matches(".txt"))
        #expect(!matcher1.matches("hello.txt.bak"))
        #expect(!matcher1.matches("txt"))
        
        // a?c wildcard
        options.query = "a?c"
        let matcher2 = try Matcher(options: options)
        #expect(matcher2.matches("abc"))
        #expect(matcher2.matches("axc"))
        #expect(!matcher2.matches("abbc"))
        #expect(!matcher2.matches("ac"))
    }
    
    @Test func testRegexMode() throws {
        var options = SearchOptions()
        options.matchMode = .regex
        options.caseSensitive = false
        
        // Regex: anchored start (^swift)
        options.query = "^swift"
        let matcher1 = try Matcher(options: options)
        #expect(matcher1.matches("swift is cool"))
        #expect(matcher1.matches("Swift is cool"))
        #expect(!matcher1.matches("cool swift"))
        
        // Regex: digit class
        options.query = "\\d+"
        let matcher2 = try Matcher(options: options)
        #expect(matcher2.matches("room 101"))
        #expect(!matcher2.matches("room one"))
    }
}

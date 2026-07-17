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

    @Test func testInvalidSearchExpressionThrows() throws {
        var options = SearchOptions()
        options.query = "<foo"

        #expect(throws: SearchQueryError.self) {
            _ = try SearchQueryPlan.parse(options.query).compile(options: options)
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

    @Test func contentIndexPrefilterRequiresALiteralInEveryBooleanBranch() throws {
        var options = SearchOptions()
        options.target = .content
        options.matchMode = .substring

        options.query = "content:shared AND (content:left OR content:right)"
        var query = try SearchQueryPlan.parse(options.query).compile(options: options)
        #expect(query.requiredContentIndexTerm(options: options) == "shared")

        options.query = "content:left OR content:right"
        query = try SearchQueryPlan.parse(options.query).compile(options: options)
        #expect(query.requiredContentIndexTerm(options: options) == nil)

        options.query = "content:needle OR content:needle"
        query = try SearchQueryPlan.parse(options.query).compile(options: options)
        #expect(query.requiredContentIndexTerm(options: options) == "needle")

        options.query = "NOT content:needle"
        query = try SearchQueryPlan.parse(options.query).compile(options: options)
        #expect(query.requiredContentIndexTerm(options: options) == nil)

        options.query = "wholeword"
        options.matchMode = .wholeWord
        query = try SearchQueryPlan.parse(options.query).compile(options: options)
        #expect(query.requiredContentIndexTerm(options: options) == "wholeword")

        options.query = "wild*card"
        options.matchMode = .wildcard
        query = try SearchQueryPlan.parse(options.query).compile(options: options)
        #expect(query.requiredContentIndexTerm(options: options) == nil)

        options.query = "你好世界"
        options.matchMode = .substring
        query = try SearchQueryPlan.parse(options.query).compile(options: options)
        #expect(query.requiredContentIndexTerm(options: options) == nil)

        options.query = "ab"
        query = try SearchQueryPlan.parse(options.query).compile(options: options)
        #expect(query.requiredContentIndexTerm(options: options) == nil)
    }

    @Test func unlimitedStreamingFastPathOnlyAcceptsEquivalentLiteralQueries() throws {
        var options = SearchOptions()
        options.maxContentFileSize = 0

        options.query = "content:Needle"
        options.target = .name
        options.matchMode = .regex
        var query = try SearchQueryPlan.parse(options.query).compile(options: options)
        #expect(query.streamingContentLiteral(options: options) == "Needle")

        options.query = "Needle"
        query = try SearchQueryPlan.parse(options.query).compile(options: options)
        #expect(query.streamingContentLiteral(options: options) == nil)

        options.target = .content
        options.matchMode = .substring
        query = try SearchQueryPlan.parse(options.query).compile(options: options)
        #expect(query.streamingContentLiteral(options: options) == "Needle")

        options.query = "ext:log content:Needle"
        query = try SearchQueryPlan.parse(options.query).compile(options: options)
        #expect(query.streamingContentLiteral(options: options) == nil)

        options.query = "wild*card"
        options.matchMode = .wildcard
        query = try SearchQueryPlan.parse(options.query).compile(options: options)
        #expect(query.streamingContentLiteral(options: options) == nil)
    }
}

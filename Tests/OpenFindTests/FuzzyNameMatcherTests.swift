import Foundation
import Testing
@testable import OpenFind

@Suite("Fuzzy Filename Matching")
struct FuzzyNameMatcherTests {
    @Test func matchesAcronymsAndCamelCaseBoundaries() {
        let matcher = FuzzyNameMatcher("svm")
        #expect(matcher.rank("SearchViewModel.swift") != nil)
        #expect(matcher.rank("search_view_model.swift") != nil)
        #expect(matcher.rank("clipboard.swift") == nil)
    }

    @Test func ranksExactStemAndPrefixBeforeLooseSubsequence() {
        let matcher = FuzzyNameMatcher("report")
        let exact = matcher.rank("report")
        let stem = matcher.rank("report.pdf")
        let prefix = matcher.rank("reports-2026.txt")
        let loose = matcher.rank("annual-report-notes.txt")
        #expect(exact != nil)
        #expect(stem != nil)
        #expect(prefix != nil)
        #expect(loose != nil)
        #expect(exact! < stem!)
        #expect(stem! < prefix!)
        #expect(prefix! < loose!)
    }

    @Test func toleratesOneAlphabeticEditButNeverChangesDigits() {
        let matcher = FuzzyNameMatcher("manifest")
        #expect(matcher.rank("manifset.json") != nil)
        #expect(FuzzyNameMatcher("report98").rank("report99.txt") == nil)
    }

    @Test func queryPlanUsesFuzzyNamesOnlyForNameMatching() throws {
        var options = SearchOptions()
        options.query = "svm"
        options.matchMode = .fuzzy
        options.target = .name
        let query = try SearchQueryPlan.parse(options.query).compile(options: options)
        #expect(query.matchesNameFilter("SearchViewModel.swift"))
        #expect(!query.shouldRunContentBranch(options: options))
    }
}

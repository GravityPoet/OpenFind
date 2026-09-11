import Foundation

struct QuickSearchFileResponse: Sendable {
    var results: [SearchResult] = []
    var isIndexing = false
    var needsFullSearch = false
}

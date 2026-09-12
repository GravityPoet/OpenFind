import Foundation
import Testing
@testable import OpenFind

@MainActor
struct ApplicationCacheTests {
    @Test func staleCacheReturnsWhileOneBackgroundRefreshIsBlocked() async throws {
        let discovery = PausedApplicationDiscovery()
        let index = ApplicationSearchIndex(refreshInterval: 0, discover: { await discovery.load() })
        await index.prewarm()
        var first: [ApplicationSearchResult]?
        let query = Task { first = await index.results(for: "Old") }
        for _ in 0..<100 {
            if first != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(first?.first?.name == "Old")
        #expect(await index.results(for: "Old").count == 1)
        #expect(await discovery.count == 2)
        await discovery.resume()
        await query.value
        await index.prewarm()
        #expect(await index.results(for: "New").first?.name == "New")
    }
}

private actor PausedApplicationDiscovery {
    private(set) var count = 0
    private var waiter: CheckedContinuation<Void, Never>?
    private var resumed = false

    func load() async -> [ApplicationSearchResult] {
        count += 1
        if count > 1, !resumed { await withCheckedContinuation { waiter = $0 } }
        let name = count == 1 ? "Old" : "New"
        return [.init(url: URL(fileURLWithPath: "/Applications/\(name).app"), name: name, bundleIdentifier: name)]
    }

    func resume() { resumed = true; waiter?.resume(); waiter = nil }
}

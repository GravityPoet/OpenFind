import Testing
import Foundation
@testable import OpenFind

@Suite("SearchEngine Tests")
struct SearchEngineTests {
    
    private func createTempDirectory() throws -> URL {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("OpenFindTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }
    
    private func writeFile(at url: URL, content: String) throws {
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func createCacheURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("OpenFindEngineCache-\(UUID().uuidString).bin")
    }
    
    @Test func testSearchEngineOptionsAndFilters() async throws {
        let root = try createTempDirectory()
        
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        
        let cacheURL = createCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let store = SearchIndexStore(persistenceURL: cacheURL)
        
        let file1 = root.appendingPathComponent("apple_name.txt")
        let file2 = root.appendingPathComponent("banana_name.txt")
        let hiddenFile = root.appendingPathComponent(".hidden_apple.txt")
        let packageDir = root.appendingPathComponent("TestPackage.bundle")
        try FileManager.default.createDirectory(at: packageDir, withIntermediateDirectories: true)
        let packageFile = packageDir.appendingPathComponent("package_apple.txt")
        
        let smallFile = root.appendingPathComponent("small.txt")
        let largeFile = root.appendingPathComponent("large.txt")
        
        try writeFile(at: file1, content: "This is some random text.")
        try writeFile(at: file2, content: "Contains word apple in content.")
        try writeFile(at: hiddenFile, content: "apple")
        try writeFile(at: packageFile, content: "apple")
        
        try writeFile(at: smallFile, content: String(repeating: "a", count: 40) + "apple") // 45 bytes
        try writeFile(at: largeFile, content: String(repeating: "a", count: 190) + "apple") // 195 bytes
        
        // 1. FileName search only
        do {
            var options = SearchOptions()
            options.query = "apple"
            options.target = .name
            options.includeHidden = true
            options.includePackages = true
            
            let stream = SearchEngine.search(scopes: [root], options: options, store: store)
            var results: [SearchResult] = []
            for await result in stream {
                results.append(result)
            }
            
            #expect(results.count == 3)
            let names = results.map { $0.name }
            #expect(names.contains("apple_name.txt"))
            #expect(names.contains(".hidden_apple.txt"))
            #expect(names.contains("package_apple.txt"))
        }
        
        // 2. Content search only
        do {
            var options = SearchOptions()
            options.query = "apple"
            options.target = .content
            options.includeHidden = false
            options.includePackages = false
            options.maxContentFileSize = 1024 * 1024
            
            let stream = SearchEngine.search(scopes: [root], options: options, store: store)
            var results: [SearchResult] = []
            for await result in stream {
                results.append(result)
            }
            
            let paths = results.map { $0.url.lastPathComponent }
            #expect(paths.contains("banana_name.txt"))
            #expect(paths.contains("small.txt"))
            #expect(paths.contains("large.txt"))
            #expect(!paths.contains("apple_name.txt"))
            #expect(!paths.contains(".hidden_apple.txt"))
            #expect(!paths.contains("package_apple.txt"))
        }
        
        // 3. MaxContentFileSize filter
        do {
            var options = SearchOptions()
            options.query = "apple"
            options.target = .content
            options.includeHidden = false
            options.includePackages = false
            options.maxContentFileSize = 100
            
            let stream = SearchEngine.search(scopes: [root], options: options, store: store)
            var results: [SearchResult] = []
            for await result in stream {
                results.append(result)
            }
            
            let paths = results.map { $0.url.lastPathComponent }
            #expect(paths.contains("small.txt"))
            #expect(!paths.contains("large.txt"))
        }
        
        // 4. Include Hidden
        do {
            var options = SearchOptions()
            options.query = "apple"
            options.target = .both
            options.includeHidden = true
            options.includePackages = false
            
            let stream = SearchEngine.search(scopes: [root], options: options, store: store)
            var results: [SearchResult] = []
            for await result in stream {
                results.append(result)
            }
            
            let paths = results.map { $0.url.lastPathComponent }
            #expect(paths.contains(".hidden_apple.txt"))
        }
    }
    
    @Test func testSearchEngineCancellation() async throws {
        let root = try createTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        
        let cacheURL = createCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let store = SearchIndexStore(persistenceURL: cacheURL)
        
        for i in 0..<100 {
            let file = root.appendingPathComponent("file_\(i).txt")
            try writeFile(at: file, content: "This is test query \(i) to cancel.")
        }
        
        var options = SearchOptions()
        options.query = "query"
        options.target = .content
        
        let stream = SearchEngine.search(scopes: [root], options: options, store: store)
        
        actor SafeCounter {
            var count = 0
            func increment() { count += 1 }
            func get() -> Int { count }
        }
        let counter = SafeCounter()
        
        let searchTask = Task {
            for await _ in stream {
                await counter.increment()
                let current = await counter.get()
                if current == 5 {
                    break
                }
            }
        }
        
        _ = await searchTask.result
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        let finalCount = await counter.get()
        #expect(finalCount <= 5)
    }

    @Test func broadNameSearchKeepsEveryResultPastTheVisiblePage() async throws {
        let root = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let cacheURL = createCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let store = SearchIndexStore(persistenceURL: cacheURL)
        let expectedCount = 2_025
        for index in 0..<expectedCount {
            let path = root.appendingPathComponent("broad-match-\(index).txt").path
            #expect(FileManager.default.createFile(atPath: path, contents: Data()))
        }

        var options = SearchOptions()
        options.query = "broad-match"
        options.target = .name

        var paths = Set<String>()
        for await batch in SearchEngine.searchBatches(scopes: [root], options: options, store: store) {
            #expect(!batch.isEmpty)
            paths.formUnion(batch.map(\.path))
        }

        #expect(paths.count == expectedCount)

        let snapshot = try #require(await SearchEngine.nameResultSnapshot(
            scopes: [root],
            options: options,
            store: store
        ))
        #expect(snapshot.count == expectedCount)
        #expect(snapshot.usesCompactReferences)
        #expect(snapshot.bytesPerStoredMatch == MemoryLayout<Int32>.stride)
        var compactPaths = Set<String>()
        var offset = 0
        while offset < snapshot.count {
            let page = await SearchEngine.materializeNamePage(
                from: snapshot,
                startingAt: offset,
                count: 2_000
            )
            compactPaths.formUnion(page.results.map(\.path))
            #expect(page.nextOffset > offset)
            offset = page.nextOffset
        }
        #expect(compactPaths == paths)
    }

    @Test func broadValidationPolicyKeepsTheVerifiedHeadWithoutCrawlingTheTail() {
        #expect(SearchEngine.shouldValidateCompleteNameTail(25_000))
        #expect(!SearchEngine.shouldValidateCompleteNameTail(25_001))
    }

    @Test func compactNamePageValidatesOnlyInspectedRowsAndKeepsTheTail() async throws {
        let root = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let firstLive = root.appendingPathComponent("visible-live.txt")
        let tailLive = root.appendingPathComponent("tail-live.txt")
        try writeFile(at: firstLive, content: "")
        try writeFile(at: tailLive, content: "")

        func node(path: String) -> ResolvedNode {
            ResolvedNode(
                node: IndexedFileNode(
                    name: (path as NSString).lastPathComponent,
                    parentIndex: -1,
                    isDirectory: false,
                    size: 0,
                    modifiedTime: 0,
                    creationTime: 0,
                    isHiddenScope: false,
                    isPackageDescendant: false
                ),
                path: path
            )
        }

        let validationIndex = SearchIndex(
            signature: SearchIndexSignature(scopes: [root]),
            nodes: [],
            pathsAreFresh: false
        )
        let snapshot = SearchNameResultSnapshot(
            nodes: [
                node(path: root.appendingPathComponent("already-removed.txt").path),
                node(path: firstLive.path),
                node(path: tailLive.path),
            ],
            validationIndex: validationIndex
        )

        let firstPage = await SearchEngine.materializeNamePage(
            from: snapshot,
            startingAt: 0,
            count: 1
        )
        #expect(firstPage.results.map(\.name) == ["visible-live.txt"])
        #expect(firstPage.nextOffset == 2)
        #expect(firstPage.staleResultCount == 1)
        #expect(firstPage.nextOffset < snapshot.count)

        let secondPage = await SearchEngine.materializeNamePage(
            from: snapshot,
            startingAt: firstPage.nextOffset,
            count: 1
        )
        #expect(secondPage.results.map(\.name) == ["tail-live.txt"])
        #expect(secondPage.nextOffset == snapshot.count)
    }

    @Test func unlimitedContentSizeRemovesTheCeilingWithoutUnboundedParallelMemory() async throws {
        let root = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let cacheURL = createCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let store = SearchIndexStore(persistenceURL: cacheURL)
        try writeFile(
            at: root.appendingPathComponent("over-the-limit.txt"),
            content: String(repeating: "x", count: 2_048) + "unlimited-hit"
        )

        var options = SearchOptions()
        options.query = "unlimited-hit"
        options.target = .content
        options.maxContentFileSize = 0

        var names: [String] = []
        for await result in SearchEngine.search(scopes: [root], options: options, store: store) {
            names.append(result.name)
        }

        #expect(names == ["over-the-limit.txt"])
        #expect(options.allowsContentFileSize(Int64.max))
        #expect(SearchEngine.estimatedContentMemoryBytes(fileSize: 10, budget: 100 * 1_024 * 1_024) == 1 * 1_024 * 1_024)
        #expect(SearchEngine.estimatedContentMemoryBytes(fileSize: 1_024 * 1_024 * 1_024, budget: 100 * 1_024 * 1_024) == 100 * 1_024 * 1_024)
    }

    @Test func foregroundSearchTemporarilyPausesBackgroundReconciliation() async throws {
        let coordinator = SearchWorkCoordinator()
        coordinator.beginSearch()
        let (waiterStarted, waiterStartedContinuation) = AsyncStream.makeStream(of: Void.self)
        let waiter = Task.detached {
            let started = ContinuousClock.now
            waiterStartedContinuation.yield(())
            waiterStartedContinuation.finish()
            coordinator.waitForSearchesToFinish()
            return started.duration(to: .now)
        }

        for await _ in waiterStarted { break }
        try await Task.sleep(for: .milliseconds(50))
        coordinator.endSearch()

        let waited = await waiter.value
        #expect(waited >= .milliseconds(40))
    }

    @Test func testPinyinMatching() async throws {
        let root = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let cacheURL = createCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let store = SearchIndexStore(persistenceURL: cacheURL)

        try writeFile(at: root.appendingPathComponent("报告.docx"), content: "")
        try writeFile(at: root.appendingPathComponent("表格.xlsx"), content: "")
        try writeFile(at: root.appendingPathComponent("other.txt"), content: "")

        var options = SearchOptions()
        options.target = .name

        options.query = "bg"
        let stream = SearchEngine.search(scopes: [root], options: options, store: store)
        var results: [SearchResult] = []
        for await result in stream {
            results.append(result)
        }
        let names = Set(results.map { $0.name })
        
        // "bg" should match "报告.docx" (bao gao -> bg) and "表格.xlsx" (biao ge -> bg)
        #expect(names.contains("报告.docx"))
        #expect(names.contains("表格.xlsx"))
        #expect(!names.contains("other.txt"))
    }
}

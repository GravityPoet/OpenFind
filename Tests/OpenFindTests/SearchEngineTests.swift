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
    
    @Test func testSearchEngineOptionsAndFilters() async throws {
        let root = try createTempDirectory()
        
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        
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
            
            let stream = SearchEngine.search(scopes: [root], options: options)
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
            
            let stream = SearchEngine.search(scopes: [root], options: options)
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
            
            let stream = SearchEngine.search(scopes: [root], options: options)
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
            
            let stream = SearchEngine.search(scopes: [root], options: options)
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
        
        for i in 0..<100 {
            let file = root.appendingPathComponent("file_\(i).txt")
            try writeFile(at: file, content: "This is test query \(i) to cancel.")
        }
        
        var options = SearchOptions()
        options.query = "query"
        options.target = .content
        
        let stream = SearchEngine.search(scopes: [root], options: options)
        
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
}

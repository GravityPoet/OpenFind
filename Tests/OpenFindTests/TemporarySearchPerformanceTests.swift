import Foundation
import Darwin
import Testing
@testable import OpenFind

@Suite("Temporary Search Performance")
struct TemporarySearchPerformanceTests {
    private func processDiskBytesWritten() -> UInt64 {
        var usage = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        return status == 0 ? usage.ri_diskio_byteswritten : 0
    }

    private func peakResidentBytes() -> Int64 {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        // On macOS ru_maxrss is reported in bytes.
        return Int64(usage.ru_maxrss)
    }

    private func processPhysicalMemoryBytes() -> (current: UInt64, lifetimePeak: UInt64) {
        var usage = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        guard status == 0 else { return (0, 0) }
        return (usage.ri_phys_footprint, usage.ri_lifetime_max_phys_footprint)
    }

    private func generatedBenchmarkBody(group: Int, kilobytes: Int, marker: String) -> String {
        let targetBytes = max(1_024, kilobytes * 1_024)
        var bytes = Array("group \(group)\(marker)".utf8)
        bytes.reserveCapacity(targetBytes + 64)
        var state = UInt64(truncatingIfNeeded: group) &* 0x9E37_79B9_7F4A_7C15
            &+ 0xD1B5_4A32_D192_ED03
        while bytes.count < targetBytes {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            let identifier = String(state & 0xFFFF_FFFF, radix: 36)
            bytes.append(contentsOf: " swift search \(identifier) complete result posting ".utf8)
        }
        if bytes.count > targetBytes {
            bytes.removeLast(bytes.count - targetBytes)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    @Test func measureConfiguredColdStages() async throws {
        guard let scopePath = ProcessInfo.processInfo.environment["OPENFIND_COLD_STAGE_SCOPE"],
              !scopePath.isEmpty else { return }
        let scope = URL(fileURLWithPath: scopePath, isDirectory: true)
        let signature = SearchIndexSignature(
            scopes: [scope],
            deepIndex: true,
            hasFullDiskAccess: true
        )
        let mode = ProcessInfo.processInfo.environment["OPENFIND_COLD_STAGE_MODE"] ?? "both"
        var queryReadyIndex: SearchIndex?

        if mode == "both" || mode == "query-ready" {
            let totalStarted = ContinuousClock.now
            let scanStarted = ContinuousClock.now
            let result = await SearchIndexBuilder.buildQueryReadyWithDiagnostics(signature: signature)
            let scanElapsed = scanStarted.duration(to: .now)
            let indexStarted = ContinuousClock.now
            let index = SearchIndex(
                signature: signature,
                nodes: result.nodes,
                pathsAreFresh: true,
                hasCompleteMetadata: false
            )
            let indexElapsed = indexStarted.duration(to: .now)
            queryReadyIndex = index
            print(
                "query-ready nodes=\(result.nodes.count) unresolved=\(result.unresolvedPaths.count) "
                    + "scan=\(scanElapsed) index=\(indexElapsed) total=\(totalStarted.duration(to: .now))"
            )
        }

        if mode == "both" || mode == "complete" {
            let totalStarted = ContinuousClock.now
            let scanStarted = ContinuousClock.now
            let result = await SearchIndexBuilder.buildWithDiagnostics(
                signature: signature,
                maximumPartialNodes: 0
            )
            let scanElapsed = scanStarted.duration(to: .now)

            let indexStarted = ContinuousClock.now
            let index = SearchIndex(
                signature: signature,
                nodes: result.nodes,
                pathsAreFresh: true
            )
            let indexElapsed = indexStarted.duration(to: .now)

            let saveURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("openfind-cold-stage-\(UUID().uuidString)-v18.bin")
            defer { try? FileManager.default.removeItem(at: saveURL) }
            let saveStarted = ContinuousClock.now
            SearchIndexPersistence.save(index: index, to: saveURL)
            let saveElapsed = saveStarted.duration(to: .now)
            let totalElapsed = totalStarted.duration(to: .now)

            if let queryReadyIndex {
                let queryReadyPaths = Set(queryReadyIndex.nodes.indices.map(queryReadyIndex.path(for:)))
                let completePaths = Set(index.nodes.indices.map(index.path(for:)))
                #expect(queryReadyPaths == completePaths)
                print("query-ready-equivalence paths=\(queryReadyPaths.count) equal=\(queryReadyPaths == completePaths)")
            }

            print(
                "cold-stage nodes=\(result.nodes.count) unresolved=\(result.unresolvedPaths.count) "
                    + "scan=\(scanElapsed) index=\(indexElapsed) save=\(saveElapsed) "
                    + "total=\(totalElapsed)"
            )
        }
    }

    @Test func measureConfiguredCache() async throws {
        guard let cachePath = ProcessInfo.processInfo.environment["OPENFIND_PERF_CACHE_PATH"],
              !cachePath.isEmpty else { return }
        let environment = ProcessInfo.processInfo.environment
        let store = SearchIndexStore(persistenceURL: URL(fileURLWithPath: cachePath))
        let scope = URL(
            fileURLWithPath: environment["OPENFIND_PERF_SCOPE"] ?? "/",
            isDirectory: true
        )
        if environment["OPENFIND_PERF_DIRECT_LOAD"] == "1" {
            let directStarted = ContinuousClock.now
            let direct = SearchIndexPersistence.load(
                signature: SearchIndexSignature(
                    scopes: [scope],
                    deepIndex: true,
                    hasFullDiskAccess: true
                ),
                from: URL(fileURLWithPath: cachePath)
            )
            print(
                "perf direct-load=\(directStarted.duration(to: .now)) "
                    + "nodes=\(direct?.nodes.count ?? 0) "
                    + "mapped=\(direct?.usesPersistedMappedNameIndex ?? false)"
            )
        }
        let rounds = max(1, Int(environment["OPENFIND_PERF_ROUNDS"] ?? "6") ?? 6)
        let outputDirectory = environment["OPENFIND_PERF_OUTPUT_DIR"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        var options = SearchOptions()
        options.target = .name
        options.deepIndex = true
        options.includeHidden = true
        options.includePackages = true
        options.useFrequencyRanking = false
        let configuredQueries = environment["OPENFIND_PERF_QUERIES"]?
            .split(separator: ",")
            .map(String.init)
            .filter { !$0.isEmpty }
        let queries = configuredQueries?.isEmpty == false
            ? configuredQueries!
            : ["swiftui", "OpenFindAfterZ9A7C2"]

        options.query = "OpenFindWarmupZ9A7C2"
        let snapshotStarted = ContinuousClock.now
        let preparedIndex = await store.snapshot(
            for: [scope],
            deepIndex: true,
            hasFullDiskAccess: true
        )
        print(
            "perf cache-snapshot=\(snapshotStarted.duration(to: .now)) "
                + "mapped=\(preparedIndex.usesPersistedMappedNameIndex)"
        )
        let loadStarted = ContinuousClock.now
        _ = await SearchEngine.nameResultSnapshot(
            scopes: [scope], options: options, store: store
        )
        print("perf load-and-warm=\(loadStarted.duration(to: .now))")
        if environment["OPENFIND_PERF_PERSIST_NAME_INDEX"] == "1" {
            let index = await store.snapshot(
                for: [scope],
                deepIndex: true,
                hasFullDiskAccess: true
            )
            SearchIndexPersistence.save(
                index: index,
                to: URL(fileURLWithPath: cachePath),
                removeDelta: false
            )
            let persistedNameIndexPath = SearchIndexPersistence.nameIndexURL(
                for: URL(fileURLWithPath: cachePath)
            ).path
            print("perf persisted-name-index=\(persistedNameIndexPath)")
        }

        for round in 0..<rounds {
            for queryOffset in queries.indices {
                let query = queries[(queryOffset + round) % queries.count]
                let started = ContinuousClock.now
                options.query = query
                let snapshot = await SearchEngine.nameResultSnapshot(
                    scopes: [scope], options: options, store: store
                )
                let snapshotElapsed = started.duration(to: .now)
                let page = if let snapshot {
                    await SearchEngine.materializeNamePage(
                        from: snapshot, startingAt: 0, count: 2_000
                    )
                } else {
                    SearchNameResultPage(results: [], nextOffset: 0, staleResultCount: 0)
                }
                print(
                    "perf query=\(query) round=\(round) count=\(snapshot?.count ?? 0) "
                        + "page=\(page.results.count) snapshot=\(snapshotElapsed) "
                        + "total=\(started.duration(to: .now))"
                )
            }
        }
        print("perf peak-rss=\(peakResidentBytes())")

        if let outputDirectory {
            try FileManager.default.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true
            )
            for (queryIndex, query) in queries.enumerated() {
                options.query = query
                guard let snapshot = await SearchEngine.nameResultSnapshot(
                    scopes: [scope], options: options, store: store
                ) else { continue }

                var offset = 0
                var staleResultCount = 0
                var paths: [String] = []
                paths.reserveCapacity(snapshot.count)
                while offset < snapshot.count {
                    let page = await SearchEngine.materializeNamePage(
                        from: snapshot,
                        startingAt: offset,
                        count: 10_000
                    )
                    guard page.nextOffset > offset else { break }
                    offset = page.nextOffset
                    staleResultCount += page.staleResultCount
                    paths.append(contentsOf: page.results.map(\.path))
                }
                paths.sort()
                let body = paths.joined(separator: "\n") + (paths.isEmpty ? "" : "\n")
                let output = outputDirectory.appendingPathComponent(
                    String(format: "%02d-openfind.txt", queryIndex)
                )
                try body.write(to: output, atomically: true, encoding: .utf8)
                print(
                    "validation query=\(query) count=\(paths.count) "
                        + "stale=\(staleResultCount) output=\(output.path)"
                )
            }
        }
    }

    @Test func generateConfiguredPersistedNameIndex() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let cachePath = environment["OPENFIND_NAME_BENCHMARK_CACHE"],
              let rawNodeCount = environment["OPENFIND_NAME_BENCHMARK_NODES"],
              let nodeCount = Int(rawNodeCount), nodeCount >= 1_024 else { return }

        let cacheURL = URL(fileURLWithPath: cachePath)
        let scope = URL(fileURLWithPath: "/openfind-generated-name-benchmark", isDirectory: true)
        let signature = SearchIndexSignature(
            scopes: [scope],
            deepIndex: true,
            hasFullDiskAccess: true
        )
        var nodes = [IndexedFileNode(
            name: scope.path,
            parentIndex: -1,
            isDirectory: true,
            size: 0,
            modifiedTime: 0,
            creationTime: 0,
            isHiddenScope: false,
            isPackageDescendant: false
        )]
        nodes.reserveCapacity(nodeCount + 1)
        for index in 0..<nodeCount {
            let name: String
            if index.isMultiple(of: 997) {
                name = "mappedneedle-\(index).swift"
            } else if index.isMultiple(of: 4) {
                name = "shared-name-\(index % 1_000).txt"
            } else {
                name = "generated-name-\(index).swift"
            }
            nodes.append(IndexedFileNode(
                name: name,
                parentIndex: 0,
                isDirectory: false,
                size: Int64(index),
                modifiedTime: 0,
                creationTime: 0,
                isHiddenScope: false,
                isPackageDescendant: false
            ))
        }

        let index = SearchIndex(
            signature: signature,
            nodes: nodes,
            pathsAreFresh: true
        )
        SearchIndexPersistence.save(index: index, to: cacheURL)
        let physicalMemory = processPhysicalMemoryBytes()
        #expect(index.usesPersistedMappedNameIndex)
        let nameIndexURL = SearchIndexPersistence.nameIndexURL(for: cacheURL)
        #expect(FileManager.default.fileExists(atPath: cacheURL.path))
        #expect(FileManager.default.fileExists(atPath: nameIndexURL.path))
        let baseBytes = (try? cacheURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let nameBytes = (try? nameIndexURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        print(
            "name-index-generate nodes=\(nodeCount) base=\(baseBytes) "
                + "sidecar=\(nameBytes) physical=\(physicalMemory.current) "
                + "peak-physical=\(physicalMemory.lifetimePeak)"
        )
        if let rawMaximum = environment["OPENFIND_NAME_BENCHMARK_MAX_GENERATE_PHYSICAL_MB"],
           let maximumMegabytes = UInt64(rawMaximum), maximumMegabytes > 0 {
            #expect(physicalMemory.lifetimePeak <= maximumMegabytes * 1_024 * 1_024)
        }
    }

    @Test func measureConfiguredCompactTopologyReplacement() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let cachePath = environment["OPENFIND_NAME_BENCHMARK_CACHE"],
              let rawNodeCount = environment["OPENFIND_NAME_BENCHMARK_NODES"],
              let nodeCount = Int(rawNodeCount), nodeCount >= 1_024 else { return }

        let cacheURL = URL(fileURLWithPath: cachePath)
        let scope = URL(fileURLWithPath: "/openfind-generated-name-benchmark", isDirectory: true)
        let signature = SearchIndexSignature(
            scopes: [scope],
            deepIndex: true,
            hasFullDiskAccess: true
        )
        let oldIndex = try #require(SearchIndexPersistence.load(
            signature: signature,
            from: cacheURL
        ))
        #expect(oldIndex.usesPersistedMappedNameIndex)

        let replacementURL = cacheURL.deletingLastPathComponent()
            .appendingPathComponent("replacement-v18.bin")
        defer {
            for url in [
                replacementURL,
                SearchIndexPersistence.nameIndexURL(for: replacementURL),
                SearchIndexPersistence.deltaURL(for: replacementURL),
            ] {
                try? FileManager.default.removeItem(at: url)
            }
        }

        var options = SearchOptions(query: "mappedneedle")
        options.target = .name
        options.deepIndex = true
        options.includeHidden = true
        options.includePackages = true
        options.useFrequencyRanking = false
        let query = try SearchQueryPlan.parse(options.query).compile(options: options)
        var actualCount = 0
        withExtendedLifetime(oldIndex) {
            var nodes = [IndexedFileNode(
                name: scope.path,
                parentIndex: -1,
                isDirectory: true,
                size: 0,
                modifiedTime: 1,
                creationTime: 1,
                isHiddenScope: false,
                isPackageDescendant: false
            )]
            nodes.reserveCapacity(nodeCount + 1)
            for index in 0..<nodeCount {
                let name: String
                if index.isMultiple(of: 997) {
                    name = "mappedneedle-\(index).swift"
                } else if index.isMultiple(of: 4) {
                    name = "shared-name-\(index % 1_000).txt"
                } else {
                    name = "generated-name-\(index).swift"
                }
                nodes.append(IndexedFileNode(
                    name: name,
                    parentIndex: 0,
                    isDirectory: false,
                    size: Int64(index),
                    modifiedTime: 1,
                    creationTime: 1,
                    isHiddenScope: false,
                    isPackageDescendant: false
                ))
            }

            let replacement = SearchIndex(
                signature: signature,
                nodes: nodes,
                pathsAreFresh: true,
                deferNameIndexBuild: true
            )
            SearchIndexPersistence.save(index: replacement, to: replacementURL)
            actualCount = replacement.nameMatches(query: query, options: options).count
        }

        let expectedCount = (nodeCount + 996) / 997
        let physicalMemory = processPhysicalMemoryBytes()
        print(
            "topology-replacement nodes=\(nodeCount) expected=\(expectedCount) "
                + "actual=\(actualCount) physical=\(physicalMemory.current) "
                + "peak-physical=\(physicalMemory.lifetimePeak)"
        )
        #expect(actualCount == expectedCount)
        let maximumMegabytes = UInt64(
            environment["OPENFIND_TOPOLOGY_BENCHMARK_MAX_PHYSICAL_MB"] ?? "1536"
        ) ?? 1_536
        #expect(physicalMemory.lifetimePeak <= maximumMegabytes * 1_024 * 1_024)
    }

    @Test func compareConfiguredPersistedNameIndexWithLinearOracle() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let cachePath = environment["OPENFIND_NAME_EQUIVALENCE_CACHE"],
              let scopePath = environment["OPENFIND_NAME_EQUIVALENCE_SCOPE"] else { return }
        let cacheURL = URL(fileURLWithPath: cachePath)
        let scope = URL(fileURLWithPath: scopePath, isDirectory: true)
        let signature = SearchIndexSignature(
            scopes: [scope],
            deepIndex: true,
            hasFullDiskAccess: true
        )
        let baseline = try #require(SearchIndexPersistence.load(
            signature: signature,
            from: cacheURL
        ))
        #expect(!baseline.usesPersistedMappedNameIndex)
        let queries = (environment["OPENFIND_NAME_EQUIVALENCE_QUERIES"]
            ?? "swiftui,OpenFindAfterZ9A7C2,package")
            .split(separator: ",")
            .map(String.init)
            .filter { !$0.isEmpty }

        var baselinePaths: [String: [String]] = [:]
        for rawQuery in queries {
            var options = SearchOptions(query: rawQuery)
            options.target = .name
            options.deepIndex = true
            options.includeHidden = true
            options.includePackages = true
            options.useFrequencyRanking = false
            let query = try SearchQueryPlan.parse(rawQuery).compile(options: options)
            baselinePaths[rawQuery] = baseline.nameMatches(
                query: query,
                options: options
            ).map(\.path)
        }

        SearchIndexPersistence.save(index: baseline, to: cacheURL, removeDelta: false)
        let mapped = try #require(SearchIndexPersistence.load(
            signature: signature,
            from: cacheURL
        ))
        #expect(mapped.usesPersistedMappedNameIndex)
        for rawQuery in queries {
            var options = SearchOptions(query: rawQuery)
            options.target = .name
            options.deepIndex = true
            options.includeHidden = true
            options.includePackages = true
            options.useFrequencyRanking = false
            let query = try SearchQueryPlan.parse(rawQuery).compile(options: options)
            let mappedPaths = mapped.nameMatches(query: query, options: options).map(\.path)
            let expectedPaths = baselinePaths[rawQuery] ?? []
            let exact = mappedPaths == expectedPaths
            if !exact {
                let expectedSet = Set(expectedPaths)
                let mappedSet = Set(mappedPaths)
                let firstOrderDifference = zip(expectedPaths, mappedPaths)
                    .first(where: { $0 != $1 })
                print(
                    "name-index-equivalence-difference query=\(rawQuery) "
                        + "expected=\(expectedPaths.count) actual=\(mappedPaths.count) "
                        + "missing=\(expectedSet.subtracting(mappedSet).prefix(3)) "
                        + "extra=\(mappedSet.subtracting(expectedSet).prefix(3)) "
                        + "firstOrder=\(String(describing: firstOrderDifference))"
                )
            }
            #expect(exact)
            print(
                "name-index-equivalence query=\(rawQuery) "
                    + "count=\(mappedPaths.count) exact=\(exact)"
            )
        }
    }

    @Test func measureConfiguredPersistedNameIndex() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let cachePath = environment["OPENFIND_NAME_BENCHMARK_CACHE"],
              let rawNodeCount = environment["OPENFIND_NAME_BENCHMARK_NODES"],
              let nodeCount = Int(rawNodeCount), nodeCount >= 1_024 else { return }

        let cacheURL = URL(fileURLWithPath: cachePath)
        let scope = URL(fileURLWithPath: "/openfind-generated-name-benchmark", isDirectory: true)
        let signature = SearchIndexSignature(
            scopes: [scope],
            deepIndex: true,
            hasFullDiskAccess: true
        )
        let loadStarted = ContinuousClock.now
        let loaded = try #require(SearchIndexPersistence.load(
            signature: signature,
            from: cacheURL
        ))
        let loadElapsed = loadStarted.duration(to: .now)
        #expect(loaded.usesPersistedMappedNameIndex)
        #expect(loaded.nodes.count == nodeCount + 1)

        var options = SearchOptions(query: "mappedneedle")
        options.target = .name
        options.deepIndex = true
        options.includeHidden = true
        options.includePackages = true
        options.useFrequencyRanking = false
        let query = try SearchQueryPlan.parse(options.query).compile(options: options)
        let queryStarted = ContinuousClock.now
        let results = loaded.nameMatches(query: query, options: options)
        let queryElapsed = queryStarted.duration(to: .now)
        let expectedCount = (nodeCount + 996) / 997
        #expect(results.count == expectedCount)
        #expect(results.allSatisfy { $0.name.contains("mappedneedle") })

        let loadMilliseconds = Self.milliseconds(loadElapsed)
        let queryMilliseconds = Self.milliseconds(queryElapsed)
        let peakRSS = peakResidentBytes()
        let maximumLoadMilliseconds = Int64(
            environment["OPENFIND_NAME_BENCHMARK_MAX_LOAD_MS"] ?? "5000"
        ) ?? 5_000
        let maximumQueryMilliseconds = Int64(
            environment["OPENFIND_NAME_BENCHMARK_MAX_QUERY_MS"] ?? "1000"
        ) ?? 1_000
        let maximumRSS = Int64(
            environment["OPENFIND_NAME_BENCHMARK_MAX_RSS_MB"] ?? "768"
        ) ?? 768

        print(
            "name-index-load nodes=\(nodeCount) load-ms=\(loadMilliseconds) "
                + "query-ms=\(queryMilliseconds) peak-rss=\(peakRSS) "
                + "expected=\(expectedCount) actual=\(results.count) mapped=true"
        )
        #expect(loadMilliseconds <= maximumLoadMilliseconds)
        #expect(queryMilliseconds <= maximumQueryMilliseconds)
        #expect(peakRSS <= maximumRSS * 1_024 * 1_024)
    }

    private static func milliseconds(_ duration: Duration) -> Int64 {
        let components = duration.components
        return components.seconds * 1_000
            + components.attoseconds / 1_000_000_000_000_000
    }

    @Test func measureGeneratedContentIndex() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let rawFileCount = environment["OPENFIND_CONTENT_BENCHMARK_FILES"],
              let fileCount = Int(rawFileCount), fileCount > 0 else { return }
        let bodyKilobytes = max(1, Int(environment["OPENFIND_CONTENT_BENCHMARK_KB"] ?? "16") ?? 16)
        let copiesPerBody = max(1, Int(environment["OPENFIND_CONTENT_BENCHMARK_COPIES"] ?? "4") ?? 4)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenFindContentBenchmark-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var expectedPaths = Set<String>()
        var inputTextBytes: Int64 = 0
        for index in 0..<fileCount {
            let group = index / copiesPerBody
            let marker = group.isMultiple(of: 97) ? " losslessbenchmarkneedle " : " ordinarycontent "
            let body = generatedBenchmarkBody(group: group, kilobytes: bodyKilobytes, marker: marker)
            let directory = root.appendingPathComponent("bucket-\(index / 500)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("document-\(index).txt")
            try body.write(to: url, atomically: false, encoding: .utf8)
            inputTextBytes += Int64(body.utf8.count)
            if group.isMultiple(of: 97) { expectedPaths.insert(url.path) }
        }

        let signature = SearchIndexSignature(scopes: [root], deepIndex: true)
        let builtNodes = await SearchIndexBuilder.build(signature: signature)
        let fileIndex = SearchIndex(signature: signature, nodes: builtNodes, pathsAreFresh: true)
        let contentIndex = ContentSearchIndex(databaseURL: root.appendingPathComponent("content.sqlite3"))
        let writtenBefore = processDiskBytesWritten()
        let started = ContinuousClock.now
        await BackgroundContentIndexEnricher.enrich(
            index: fileIndex,
            contentIndex: contentIndex,
            maxFileSize: 32 * 1_024 * 1_024,
            maximumDatabaseBytes: 4 * 1_024 * 1_024 * 1_024
        )
        let elapsed = started.duration(to: .now)
        let writtenAfter = processDiskBytesWritten()
        let diagnostics = await contentIndex.diagnostics()

        let warmReconcileStarted = ContinuousClock.now
        await BackgroundContentIndexEnricher.enrich(
            index: fileIndex,
            contentIndex: contentIndex,
            maxFileSize: 32 * 1_024 * 1_024,
            maximumDatabaseBytes: 4 * 1_024 * 1_024 * 1_024
        )
        let warmReconcileMilliseconds = Self.milliseconds(
            warmReconcileStarted.duration(to: .now)
        )
        let warmDiagnostics = await contentIndex.diagnostics()

        var candidates: [ContentIndexCandidate] = []
        candidates.reserveCapacity(fileCount)
        for (index, node) in fileIndex.nodes.enumerated() where !node.isDirectory {
            candidates.append(ContentIndexCandidate(
                node: ResolvedNode(node: node, path: fileIndex.path(for: index)),
                forceRefresh: false
            ))
        }
        let plan = await contentIndex.plan(
            candidates: candidates,
            requiredLiteral: "losslessbenchmarkneedle"
        )
        var actualPaths = Set<String>()
        for item in plan.workItems {
            let text = try? String(contentsOf: item.node.url, encoding: .utf8)
            if text?.contains("losslessbenchmarkneedle") == true {
                actualPaths.insert(item.node.path)
            }
        }

        let writtenBytes = writtenAfter >= writtenBefore ? writtenAfter - writtenBefore : 0
        let writeAmplification = diagnostics.databaseBytes > 0
            ? Double(writtenBytes) / Double(diagnostics.databaseBytes)
            : 0
        let peakRSS = peakResidentBytes()
        print(
            "content-benchmark files=\(fileCount) copies=\(copiesPerBody) "
                + "input=\(inputTextBytes) database=\(diagnostics.databaseBytes) "
                + "written=\(writtenBytes) write-amplification=\(writeAmplification) "
                + "transactions=\(diagnostics.recordTransactions) "
                + "unique=\(diagnostics.uniqueContentBodies) deduplicated=\(diagnostics.deduplicatedDocuments) "
                + "peak-rss=\(peakRSS) elapsed=\(elapsed) "
                + "warm-reconcile-ms=\(warmReconcileMilliseconds) "
                + "expected=\(expectedPaths.count) actual=\(actualPaths.count)"
        )

        #expect(actualPaths == expectedPaths)
        #expect(diagnostics.indexedDocuments == fileCount)
        #expect(diagnostics.uniqueContentBodies == (fileCount + copiesPerBody - 1) / copiesPerBody)
        #expect(diagnostics.databaseBytes <= 4 * 1_024 * 1_024 * 1_024)
        #expect(warmDiagnostics.recordTransactions == diagnostics.recordTransactions)
        let maximumWarmReconcileMilliseconds = Int64(
            environment["OPENFIND_CONTENT_BENCHMARK_MAX_WARM_RECONCILE_MS"] ?? "5000"
        ) ?? 5_000
        #expect(warmReconcileMilliseconds <= maximumWarmReconcileMilliseconds)
        let transactionsByCount = (fileCount + 4_095) / 4_096
        let transactionByteLimit: Int64 = 32 * 1_024 * 1_024
        let transactionsByBytes = Int((inputTextBytes + transactionByteLimit - 1) / transactionByteLimit)
        #expect(diagnostics.recordTransactions <= max(transactionsByCount, transactionsByBytes))
        #expect(peakRSS < 1_500 * 1_024 * 1_024)
        if fileCount >= 8_000, writtenBytes > 0 {
            #expect(writeAmplification <= 3.0)
        }
    }
}

import Foundation

/// Index-free, real-time search engine.
///
/// Each search root is walked with a `FileManager` enumerator (metadata
/// traversal is fast). Name matching happens inline; content matching is the
/// expensive part and is offloaded to a bounded-concurrency `TaskGroup`.
/// Results stream out through an `AsyncStream` so the UI can display them as
/// they arrive. Cancellation propagates through `Task`.
enum SearchEngine {

    /// Starts a search and returns an incremental result stream. The underlying
    /// traversal is cancelled automatically when the consumer stops iterating or
    /// the stream is otherwise terminated.
    static func search(scopes: [URL], options: SearchOptions) -> AsyncStream<SearchResult> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task.detached(priority: .userInitiated) {
                await run(scopes: scopes, options: options, continuation: continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .nameKey,
    ]

    private static func run(
        scopes: [URL],
        options: SearchOptions,
        continuation: AsyncStream<SearchResult>.Continuation
    ) async {
        let matcher: Matcher
        do {
            matcher = try Matcher(options: options)
        } catch {
            return // Empty query or invalid regex: finish silently; the UI guards empty queries.
        }

        var enumOptions: FileManager.DirectoryEnumerationOptions = []
        if !options.includeHidden { enumOptions.insert(.skipsHiddenFiles) }
        if !options.includePackages { enumOptions.insert(.skipsPackageDescendants) }

        let maxConcurrency = max(4, ProcessInfo.processInfo.activeProcessorCount * 2)
        let keys = resourceKeys

        await withTaskGroup(of: Void.self) { group in
            var inFlight = 0

            for scope in scopes {
                guard let enumerator = FileManager.default.enumerator(
                    at: scope,
                    includingPropertiesForKeys: Array(keys),
                    options: enumOptions
                ) else { continue }

                while let object = enumerator.nextObject() {
                    guard let url = object as? URL else { continue }
                    if Task.isCancelled { return }

                    let values = try? url.resourceValues(forKeys: keys)
                    let isDirectory = values?.isDirectory ?? false
                    let name = values?.name ?? url.lastPathComponent

                    let nameHit = matcher.matches(name)

                    // Name hit: emit immediately and skip content check (counts as
                    // a hit in `both` mode too).
                    if options.target != .content, nameHit {
                        continuation.yield(makeResult(url: url, values: values,
                                                      isDirectory: isDirectory, name: name,
                                                      matchedContent: false, preview: nil))
                        continue
                    }
                    if options.target == .name { continue }

                    // Content check needed: files only, name miss (both) or pure content mode.
                    if isDirectory { continue }

                    // Bounded concurrency: when the window is full, wait for one
                    // in-flight task to finish before submitting a new one.
                    while inFlight >= maxConcurrency {
                        await group.next()
                        inFlight -= 1
                    }
                    inFlight += 1

                    let capturedURL = url
                    let capturedValues = values
                    let capturedName = name
                    let maxSize = options.maxContentFileSize
                    group.addTask {
                        if Task.isCancelled { return }
                        guard let preview = contentMatch(url: capturedURL, matcher: matcher, maxSize: maxSize)
                        else { return }
                        continuation.yield(makeResult(url: capturedURL, values: capturedValues,
                                                      isDirectory: false, name: capturedName,
                                                      matchedContent: true, preview: preview))
                    }
                }
            }
        }
    }

    private static func makeResult(
        url: URL,
        values: URLResourceValues?,
        isDirectory: Bool,
        name: String,
        matchedContent: Bool,
        preview: String?
    ) -> SearchResult {
        SearchResult(
            url: url,
            name: name,
            path: url.path(percentEncoded: false),
            isDirectory: isDirectory,
            size: Int64(values?.fileSize ?? 0),
            modified: values?.contentModificationDate ?? .distantPast,
            matchedContent: matchedContent,
            contentPreview: preview
        )
    }

    /// Reads file contents and matches. Skips oversized and binary files, and
    /// returns a preview of the first matching line.
    private static func contentMatch(url: URL, matcher: Matcher, maxSize: Int64) -> String? {
        guard let sizeValue = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              Int64(sizeValue) <= maxSize, sizeValue > 0 else { return nil }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), !data.isEmpty else { return nil }

        // Binary heuristic: a NUL byte in the first 8 KB means "binary", skip it.
        if data.prefix(8192).contains(0) { return nil }

        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else { return nil }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if matcher.matches(String(line)) {
                return String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }
}

import Foundation

/// Command-line search mode, reusing the same `SearchEngine` as the GUI.
/// It is both a real feature and a convenient way to verify search correctness
/// headlessly.
///
/// Usage: OpenFind --search <query> [paths...] [options]
///   --content    search file contents (default: file names)
///   --both       name or contents
///   --regex      regular-expression match
///   --wildcard   wildcard match (* ?)
///   --word       whole-word match
///   --case       case-sensitive
///   --no-hidden  exclude hidden files
///   --packages   search inside .app / .bundle packages (default)
///   --no-packages
///                exclude package contents
enum CLIRunner {

    static func run(arguments: [String]) async {
        var args = Array(arguments.dropFirst())
        guard let flagIndex = args.firstIndex(where: { $0 == "--search" || $0 == "-s" }),
              flagIndex + 1 < args.count else {
            printUsage()
            exit(2)
        }

        let query = args[flagIndex + 1]
        args.removeSubrange(flagIndex...(flagIndex + 1))

        var flags = Set<String>()
        var paths: [String] = []
        for arg in args {
            if arg.hasPrefix("--") { flags.insert(arg) } else { paths.append(arg) }
        }

        let options = searchOptions(query: query, flags: flags)

        let refresh = flags.contains("--refresh")

        do {
            _ = try SearchQueryPlan.parse(options.query).compile(options: options)
        } catch {
            FileHandle.standardError.write(Data("Invalid search expression\n".utf8))
            exit(2)
        }

        let scopes = (paths.isEmpty ? [FileManager.default.currentDirectoryPath] : paths)
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        let store: SearchIndexStore
        if let cachePath = ProcessInfo.processInfo.environment["OPENFIND_CACHE_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !cachePath.isEmpty {
            store = SearchIndexStore(persistenceURL: URL(
                fileURLWithPath: (cachePath as NSString).expandingTildeInPath
            ))
        } else {
            store = .shared
        }

        let timing = flags.contains("--timing")
        let started = ContinuousClock.now
        func mark(_ label: String) {
            guard timing else { return }
            let ms = (ContinuousClock.now - started).components.attoseconds / 1_000_000_000_000_000
                + (ContinuousClock.now - started).components.seconds * 1_000
            FileHandle.standardError.write(Data("timing \(label)=\(ms)ms\n".utf8))
        }

        let hasFullDiskAccess = SearchPermissions.hasFullDiskAccess()
        if refresh {
            _ = await store.refresh(
                scopes: scopes,
                deepIndex: options.deepIndex,
                hasFullDiskAccess: hasFullDiskAccess
            )
            mark("refresh")
        } else {
            _ = await store.snapshot(
                for: scopes,
                deepIndex: options.deepIndex,
                hasFullDiskAccess: hasFullDiskAccess
            )
            mark("snapshot")
        }

        var count = 0
        for await batch in SearchEngine.searchBatches(scopes: scopes, options: options, store: store) {
            var output = ""
            output.reserveCapacity(batch.reduce(0) { $0 + $1.path.utf8.count + 1 })
            for result in batch {
                output.append(result.path)
                output.append("\n")
                if let preview = result.contentPreview {
                    output.append("    \u{21B3} ")
                    output.append(preview)
                    output.append("\n")
                }
            }
            FileHandle.standardOutput.write(Data(output.utf8))
            count += batch.count
        }
        mark("search")
        FileHandle.standardError.write(Data("\u{2014} \(count) result(s) \u{2014}\n".utf8))
        await store.flushPersistence()
        mark("flush")
        exit(0)
    }

    static func searchOptions(query: String, flags: Set<String>) -> SearchOptions {
        var options = SearchOptions(query: query)
        if flags.contains("--content") { options.target = .content }
        if flags.contains("--both") { options.target = .both }
        if flags.contains("--regex") { options.matchMode = .regex }
        if flags.contains("--wildcard") { options.matchMode = .wildcard }
        if flags.contains("--word") { options.matchMode = .wholeWord }
        options.caseSensitive = flags.contains("--case")
        if flags.contains("--hidden") { options.includeHidden = true }
        if flags.contains("--no-hidden") { options.includeHidden = false }
        if flags.contains("--packages") { options.includePackages = true }
        if flags.contains("--no-packages") { options.includePackages = false }
        if flags.contains("--deep") { options.deepIndex = true }
        return options
    }

    private static func printUsage() {
        let usage = """
        Usage: OpenFind --search <query> [paths...] [options]
          --content    search file contents (default: file names)
          --both       name or contents
          --regex      regular-expression match
          --wildcard   wildcard match (* ?)
          --word       whole-word match
          --case       case-sensitive
          --hidden     include hidden files (default)
          --no-hidden  exclude hidden files
          --packages   search inside .app / .bundle packages (default)
          --no-packages
                       exclude package contents
          --deep       include noisy cache/log/system locations in the index
          --refresh    rebuild the index before searching

        """
        FileHandle.standardError.write(Data(usage.utf8))
    }
}

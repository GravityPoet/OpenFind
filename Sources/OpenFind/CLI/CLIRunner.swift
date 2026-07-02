import Foundation

/// Command-line search mode, reusing the same `SearchEngine` as the GUI.
/// It is both a real feature (EasyFind has none) and a convenient way to verify
/// search correctness headlessly.
///
/// Usage: OpenFind --search <query> [paths...] [options]
///   --content    search file contents (default: file names)
///   --both       name or contents
///   --regex      regular-expression match
///   --wildcard   wildcard match (* ?)
///   --word       whole-word match
///   --case       case-sensitive
///   --hidden     include hidden files
///   --packages   search inside .app / .bundle packages
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

        var options = SearchOptions(query: query)
        var flags = Set<String>()
        var paths: [String] = []
        for arg in args {
            if arg.hasPrefix("--") { flags.insert(arg) } else { paths.append(arg) }
        }

        if flags.contains("--content") { options.target = .content }
        if flags.contains("--both") { options.target = .both }
        if flags.contains("--regex") { options.matchMode = .regex }
        if flags.contains("--wildcard") { options.matchMode = .wildcard }
        if flags.contains("--word") { options.matchMode = .wholeWord }
        options.caseSensitive = flags.contains("--case")
        options.includeHidden = flags.contains("--hidden")
        options.includePackages = flags.contains("--packages")
        if flags.contains("--deep") { options.deepIndex = true }

        let scopes = (paths.isEmpty ? [FileManager.default.currentDirectoryPath] : paths)
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }

        let timing = flags.contains("--timing")
        let started = ContinuousClock.now
        func mark(_ label: String) {
            guard timing else { return }
            let ms = (ContinuousClock.now - started).components.attoseconds / 1_000_000_000_000_000
                + (ContinuousClock.now - started).components.seconds * 1_000
            FileHandle.standardError.write(Data("timing \(label)=\(ms)ms\n".utf8))
        }

        _ = await SearchIndexStore.shared.snapshot(for: scopes, deepIndex: options.deepIndex)
        mark("snapshot")

        var count = 0
        for await result in SearchEngine.search(scopes: scopes, options: options) {
            print(result.path)
            if let preview = result.contentPreview {
                print("    \u{21B3} \(preview)")
            }
            count += 1
        }
        mark("search")
        FileHandle.standardError.write(Data("\u{2014} \(count) result(s) \u{2014}\n".utf8))
        await SearchIndexStore.shared.flushPersistence()
        mark("flush")
        exit(0)
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
          --hidden     include hidden files
          --packages   search inside .app / .bundle packages
          --deep       index everything (no ignore list)

        """
        FileHandle.standardError.write(Data(usage.utf8))
    }
}

import Foundation

// Callers restrict the path to their owned build/staging roots. Preserve a
// recoverable Trash receipt instead of recursively deleting an app bundle.
guard CommandLine.arguments.count == 2, CommandLine.arguments[1].hasPrefix("/") else {
    fputs("Error: pass one absolute owned build or installation path.\n", stderr)
    exit(64)
}
let source = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
guard source.path != "/", source != FileManager.default.homeDirectoryForCurrentUser else {
    fputs("Error: refusing to recycle a filesystem or user root.\n", stderr)
    exit(64)
}
let parent = source.deletingLastPathComponent()
func identity(_ url: URL) throws -> [String] {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try [FileAttributeKey.systemNumber, .systemFileNumber].map {
        guard let value = attributes[$0] as? NSNumber else { throw CocoaError(.fileReadUnknown) }
        return value.stringValue
    }
}
do {
    let before = try identity(parent)
    var destination: NSURL?
    try FileManager.default.trashItem(at: source, resultingItemURL: &destination)
    guard let destination,
          FileManager.default.fileExists(atPath: (destination as URL).path),
          !FileManager.default.fileExists(atPath: source.path),
          try identity(parent) == before else {
        throw CocoaError(.fileWriteUnknown)
    }
    let receipt = ["recycled": source.path, "trash": (destination as URL).path,
                   "parent_device": before[0], "parent_inode": before[1]]
    let data = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
} catch {
    fputs("Error: recoverable cleanup failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}

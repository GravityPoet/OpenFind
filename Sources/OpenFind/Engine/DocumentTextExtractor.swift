import AppKit
import Compression
import Darwin
import Dispatch
import Foundation
import PDFKit

struct ExtractedDocumentText: Sendable, Equatable {
    enum Source: String, Sendable {
        case plainText
        case pdf
        case attributedDocument
        case openXML
        case iWorkPreview
        case spotlightImporter
        case archive
    }

    let text: String
    let source: Source
}

/// Only controls which files receive optional background acceleration first.
/// Every indexed file remains eligible for foreground authoritative scanning.
enum BackgroundContentTier: Int, CaseIterable, Sendable {
    case preferred
    case structured
}

/// Extracts searchable text without executing document macros or writing
/// archive members to disk. Structured formats use macOS-native readers where
/// possible; process-isolated fallbacks have strict time and output ceilings.
enum DocumentTextExtractor {
    static let extractionVersion = 1

    enum StreamingPlainTextMatch: Sendable, Equatable {
        case match
        case noMatch
        /// The file is not proven to be an ASCII plain-text stream. Callers
        /// must fall back to the complete extractor for semantic correctness.
        case unsupported
    }

    private static let binarySniffBytes = 8_192
    private static let processTimeout: TimeInterval = 15
    private static let listingLimit = 16 * 1_024 * 1_024
    private static let preferredBackgroundByteLimit: Int64 = 16 * 1_024 * 1_024
    private static let deferredBackgroundPathComponents: Set<String> = [
        ".build", ".cache", ".gradle", "build", "caches", "deriveddata",
        "dist", "node_modules", "out", "target",
    ]
    private static let structuredBackgroundExtensions: Set<String> = [
        "doc", "docx", "key", "numbers", "odt", "pages", "pdf", "pptm",
        "pptx", "rtf", "rtfd", "webarchive", "xlsm", "xlsx",
    ]

    private static let attributedDocumentTypes: [String: NSAttributedString.DocumentType] = [
        "rtf": .rtf,
        "rtfd": .rtfd,
        "doc": .docFormat,
        "docx": .officeOpenXML,
        "odt": .openDocument,
        "html": .html,
        "htm": .html,
        "webarchive": .webArchive,
    ]

    private static let iWorkExtensions: Set<String> = ["pages", "numbers", "key"]
    private static let openXMLArchiveExtensions: Set<String> = ["xlsx", "xlsm", "pptx", "pptm"]
    private static let archiveSuffixes = [
        ".tar.gz", ".tar.bz2", ".tar.xz", ".tgz", ".tbz", ".tbz2", ".txz",
        ".zip", ".tar", ".gz", ".bz2", ".xz",
    ]
    private static let nestedArchiveExtensions: Set<String> = [
        "zip", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "7z", "rar",
    ]
    private static let plainTextExtensions: Set<String> = [
        "txt", "text", "md", "markdown", "rst", "adoc", "csv", "tsv", "log",
        "json", "jsonl", "yaml", "yml", "toml", "xml", "plist", "strings",
        "ini", "cfg", "conf", "config", "properties", "env", "sql", "graphql",
        "html", "htm", "css", "scss", "sass", "less", "svg",
        "c", "cc", "cpp", "cxx", "h", "hh", "hpp", "m", "mm", "swift",
        "rs", "go", "py", "pyi", "rb", "php", "java", "kt", "kts", "scala",
        "js", "jsx", "mjs", "cjs", "ts", "tsx", "vue", "svelte",
        "sh", "bash", "zsh", "fish", "ps1", "bat", "cmd",
        "tex", "bib", "srt", "vtt", "ass", "ssa", "rtf",
    ]
    private static let commonTextNames: Set<String> = [
        "readme", "license", "licence", "copying", "notice", "authors", "changelog",
        "makefile", "dockerfile", "gemfile", "rakefile", "podfile",
    ]

    static func isContentBearingDirectory(name: String) -> Bool {
        iWorkExtensions.contains((name as NSString).pathExtension.lowercased())
            || (name as NSString).pathExtension.lowercased() == "rtfd"
    }

    /// Conservative background-enrichment allowlist. Foreground content search
    /// still attempts every indexed file, so omitting an unfamiliar extension
    /// here can only defer work; it can never suppress a search result.
    static func isKnownSearchableContent(name: String, isDirectory: Bool) -> Bool {
        if isDirectory { return isContentBearingDirectory(name: name) }
        let lowerName = name.lowercased()
        let extensionName = (lowerName as NSString).pathExtension
        return extensionName == "pdf"
            || attributedDocumentTypes[extensionName] != nil
            || openXMLArchiveExtensions.contains(extensionName)
            || iWorkExtensions.contains(extensionName)
            || archiveSuffixes.contains(where: lowerName.hasSuffix)
            || plainTextExtensions.contains(extensionName)
            || commonTextNames.contains(lowerName)
    }

    /// Classifies optional background work without changing search coverage.
    /// Expensive archives, large plain text, and highly duplicated build/cache
    /// trees are searched on demand and may be cached by foreground queries.
    static func backgroundIndexTier(
        name: String,
        path: String,
        isDirectory: Bool,
        size: Int64
    ) -> BackgroundContentTier? {
        guard isKnownSearchableContent(name: name, isDirectory: isDirectory) else { return nil }
        let lowerName = name.lowercased()
        if archiveSuffixes.contains(where: lowerName.hasSuffix) { return nil }
        let pathComponents = path.split(separator: "/").map { $0.lowercased() }
        if pathComponents.contains(where: deferredBackgroundPathComponents.contains) { return nil }

        let extensionName = (lowerName as NSString).pathExtension
        if structuredBackgroundExtensions.contains(extensionName) {
            return .structured
        }
        guard !isDirectory, size <= preferredBackgroundByteLimit else { return nil }
        return .preferred
    }

    static func isArchiveURL(_ url: URL) -> Bool {
        let lowerName = url.lastPathComponent.lowercased()
        return archiveSuffixes.contains { lowerName.hasSuffix($0) }
    }

    static func mayExpandDuringExtraction(name: String) -> Bool {
        let lowerName = name.lowercased()
        let extensionName = (lowerName as NSString).pathExtension
        return archiveSuffixes.contains { lowerName.hasSuffix($0) }
            || openXMLArchiveExtensions.contains(extensionName)
            || iWorkExtensions.contains(extensionName)
            || extensionName == "rtfd"
    }

    /// A nil extraction is normally retryable. Only a successfully readable
    /// empty or NUL-bearing raw file is a durable non-text result; permission
    /// errors, structured-format failures, timeouts, and cancellation remain
    /// eligible for the authoritative path on the next query.
    static func isStableNonTextFile(_ url: URL, maxFileSize: Int64) -> Bool {
        guard !Task.isCancelled,
              let values = try? url.resourceValues(forKeys: [
                .fileSizeKey, .isDirectoryKey, .isRegularFileKey,
              ]),
              values.isDirectory != true,
              values.isRegularFile != false else { return false }
        let size = Int64(values.fileSize ?? 0)
        guard maxFileSize == 0 || size <= maxFileSize else { return false }
        if size == 0 { return true }

        let extensionName = url.pathExtension.lowercased()
        guard extensionName != "pdf",
              attributedDocumentTypes[extensionName] == nil,
              !openXMLArchiveExtensions.contains(extensionName),
              !iWorkExtensions.contains(extensionName),
              !isArchiveURL(url) else { return false }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: binarySniffBytes) else { return false }
        return prefix.contains(0)
    }

    static func extract(from url: URL, maxFileSize: Int64) -> ExtractedDocumentText? {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isDirectoryKey, .isRegularFileKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        let isDirectory = values.isDirectory == true
        let extensionName = url.pathExtension.lowercased()
        guard !isDirectory || isContentBearingDirectory(name: url.lastPathComponent) else { return nil }

        let fileSize = Int64(values.fileSize ?? 0)
        if !isDirectory {
            guard values.isRegularFile != false,
                  fileSize > 0,
                  maxFileSize == 0 || fileSize <= maxFileSize else { return nil }
        }
        // Zero means genuinely unbounded.  Structured readers still enforce
        // their own format/process limits where required, while plain text is
        // handled by the complete decoder or the bounded streaming fast path.
        let extractedByteLimit = maxFileSize == 0
            ? Int.max
            : Int(min(Int64(Int.max), max(1, maxFileSize)))

        if extensionName == "pdf" {
            guard let text = PDFDocument(url: url)?.string,
                  !text.isEmpty,
                  text.utf8.count <= extractedByteLimit else { return nil }
            return ExtractedDocumentText(text: text, source: .pdf)
        }

        if isDirectory, extensionName == "rtfd" {
            let richTextURL = url.appendingPathComponent("TXT.rtf", isDirectory: false)
            return extract(from: richTextURL, maxFileSize: maxFileSize)
        }

        if let documentType = attributedDocumentTypes[extensionName], !isDirectory {
            var attributes: NSDictionary?
            guard let attributed = try? NSAttributedString(
                url: url,
                options: [.documentType: documentType],
                documentAttributes: &attributes
            ), !attributed.string.isEmpty,
               attributed.string.utf8.count <= extractedByteLimit else { return nil }
            return ExtractedDocumentText(text: attributed.string, source: .attributedDocument)
        }

        if openXMLArchiveExtensions.contains(extensionName),
           let text = extractOpenXML(from: url, byteLimit: extractedByteLimit) {
            return ExtractedDocumentText(text: text, source: .openXML)
        }

        if iWorkExtensions.contains(extensionName) {
            if let text = extractIWorkPreview(
                from: url,
                isDirectory: isDirectory,
                byteLimit: extractedByteLimit
            ) {
                return ExtractedDocumentText(text: text, source: .iWorkPreview)
            }
            if let text = extractWithSpotlightImporter(from: url, byteLimit: extractedByteLimit) {
                return ExtractedDocumentText(text: text, source: .spotlightImporter)
            }
            return nil
        }

        if isArchiveURL(url),
           let text = extractArchive(from: url, byteLimit: extractedByteLimit) {
            return ExtractedDocumentText(text: text, source: .archive)
        }

        guard !isDirectory,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count <= extractedByteLimit,
              let text = decodePlainText(data),
              !text.isEmpty else { return nil }
        return ExtractedDocumentText(text: text, source: .plainText)
    }

    /// Searches a large, ordinary ASCII text file without materializing its
    /// contents.  Returning `.unsupported` is intentional: a non-ASCII,
    /// binary, or encoded stream must use `extract(from:maxFileSize:)`, whose
    /// Foundation decoding remains the authority for those formats.
    static func streamASCIIPlainTextMatch(
        from url: URL,
        needle: String,
        caseSensitive: Bool
    ) -> StreamingPlainTextMatch {
        guard !needle.isEmpty,
              needle.utf8.allSatisfy({ $0 < 0x80 }),
              let values = try? url.resourceValues(forKeys: [
                  .isDirectoryKey, .isRegularFileKey, .fileSizeKey,
              ]),
              values.isDirectory != true,
              values.isRegularFile != false,
              (values.fileSize ?? 0) > 0 else {
            return .unsupported
        }

        let extensionName = url.pathExtension.lowercased()
        guard !isArchiveURL(url),
              attributedDocumentTypes[extensionName] == nil,
              !openXMLArchiveExtensions.contains(extensionName),
              !iWorkExtensions.contains(extensionName),
              let handle = try? FileHandle(forReadingFrom: url) else {
            return .unsupported
        }
        defer { try? handle.close() }

        let needleBytes = Array(needle.utf8)
        let foldedNeedle = needleBytes.map(Self.asciiLowercased)
        let chunkSize = 1 * 1_024 * 1_024
        var carry = [UInt8]()
        carry.reserveCapacity(max(0, needleBytes.count - 1))
        var isFirstChunk = true

        while !Task.isCancelled {
            guard let data = try? handle.read(upToCount: chunkSize),
                  !data.isEmpty else {
                return .noMatch
            }
            let bytes = Array(data)
            if isFirstChunk {
                isFirstChunk = false
                // Encoded text and arbitrary binary data belong to the full
                // decoder.  In particular, do not treat UTF-16 NULs as ASCII.
                if bytes.starts(with: [0xFF, 0xFE])
                    || bytes.starts(with: [0xFE, 0xFF])
                    || bytes.starts(with: [0xFF, 0xFE, 0x00, 0x00])
                    || bytes.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
                    return .unsupported
                }
            }
            guard bytes.allSatisfy({ $0 < 0x80 }) else { return .unsupported }

            var window = carry
            window.append(contentsOf: bytes)
            if containsASCII(
                window,
                needle: needleBytes,
                foldedNeedle: foldedNeedle,
                caseSensitive: caseSensitive
            ) {
                return .match
            }
            if bytes.contains(0) { return .unsupported }
            if needleBytes.count > 1 {
                carry = Array(window.suffix(needleBytes.count - 1))
            } else {
                carry.removeAll(keepingCapacity: true)
            }
        }
        return .unsupported
    }

    private static func extractOpenXML(from url: URL, byteLimit: Int) -> String? {
        guard let entries = archiveEntries(in: url) else { return nil }
        let selected = entries.filter { entry in
            let lower = entry.lowercased()
            guard lower.hasSuffix(".xml") else { return false }
            let extensionName = url.pathExtension.lowercased()
            if extensionName == "xlsx" || extensionName == "xlsm" {
                return lower == "xl/sharedstrings.xml"
                    || lower.hasPrefix("xl/worksheets/")
                    || lower.hasPrefix("xl/comments")
            }
            return lower.hasPrefix("ppt/slides/")
                || lower.hasPrefix("ppt/notesslides/")
                || lower.hasPrefix("ppt/comments/")
        }
        guard !selected.isEmpty,
              let data = extractArchiveEntries(selected, from: url, byteLimit: byteLimit),
              let xml = String(data: data, encoding: .utf8) else { return nil }
        let text = visibleXMLText(xml)
        return text.isEmpty ? nil : text
    }

    private static func extractIWorkPreview(
        from url: URL,
        isDirectory: Bool,
        byteLimit: Int
    ) -> String? {
        let previewCandidates = [
            "QuickLook/Preview.pdf", "quicklook/preview.pdf", "Preview.pdf", "preview.pdf",
        ]
        if isDirectory {
            for relativePath in previewCandidates {
                let preview = url.appendingPathComponent(relativePath)
                if let text = PDFDocument(url: preview)?.string,
                   !text.isEmpty,
                   text.utf8.count <= byteLimit {
                    return text
                }
            }
            return nil
        }

        guard let entries = archiveEntries(in: url) else { return nil }
        guard let previewEntry = entries.first(where: { entry in
            previewCandidates.contains { entry.caseInsensitiveCompare($0) == .orderedSame }
        }), let data = extractArchiveEntries([previewEntry], from: url, byteLimit: byteLimit),
           let document = PDFDocument(data: data),
           let text = document.string,
           !text.isEmpty,
           text.utf8.count <= byteLimit else { return nil }
        return text
    }

    private static func extractWithSpotlightImporter(from url: URL, byteLimit: Int) -> String? {
        let outputURL = temporaryURL(extension: "plist")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        guard let result = LimitedProcess.run(
            executable: "/usr/bin/mdimport",
            arguments: ["-t", "-o", outputURL.path, url.path],
            outputLimit: 256 * 1_024,
            timeout: processTimeout
        ), result.status == 0, !result.wasLimited,
           let attributes = try? outputURL.resourceValues(forKeys: [.fileSizeKey]),
           let outputSize = attributes.fileSize,
           outputSize <= byteLimit || byteLimit > Int.max - 2 * 1_024 * 1_024,
           let data = try? Data(contentsOf: outputURL, options: .mappedIfSafe),
           let propertyList = try? PropertyListSerialization.propertyList(from: data, format: nil),
           let text = findStringValue(named: "kMDItemTextContent", in: propertyList),
           !text.isEmpty,
           text.utf8.count <= byteLimit else { return nil }
        return text
    }

    private static func findStringValue(named key: String, in value: Any) -> String? {
        if let dictionary = value as? [String: Any] {
            if let text = dictionary[key] as? String { return text }
            for nested in dictionary.values {
                if let text = findStringValue(named: key, in: nested) { return text }
            }
        } else if let array = value as? [Any] {
            for nested in array {
                if let text = findStringValue(named: key, in: nested) { return text }
            }
        }
        return nil
    }

    private static func extractArchive(from url: URL, byteLimit: Int) -> String? {
        let lowerName = url.lastPathComponent.lowercased()
        if lowerName.hasSuffix(".xz"),
           !lowerName.hasSuffix(".tar.xz"),
           !lowerName.hasSuffix(".txz") {
            guard let compressed = try? Data(contentsOf: url, options: .mappedIfSafe),
                  let data = decompressLZMA(compressed, byteLimit: byteLimit),
                  let text = decodePlainText(data),
                  !text.isEmpty else { return nil }
            return text
        }
        if !lowerName.hasSuffix(".tar.gz"), !lowerName.hasSuffix(".tar.bz2"),
           !lowerName.hasSuffix(".tar.xz"), !lowerName.hasSuffix(".tgz"),
           !lowerName.hasSuffix(".tbz"), !lowerName.hasSuffix(".tbz2"),
           !lowerName.hasSuffix(".txz"),
           let single = singleCompressedCommand(for: lowerName) {
            guard let result = LimitedProcess.run(
                executable: single.executable,
                arguments: single.arguments + [url.path],
                outputLimit: byteLimit,
                timeout: processTimeout
            ), result.status == 0, !result.wasLimited,
               let text = decodePlainText(result.output), !text.isEmpty else { return nil }
            return text
        }

        guard let entries = archiveEntries(in: url) else { return nil }
        let plainEntries = entries.filter(isPlainArchiveMember)
        let structuredEntries = entries.filter(isStructuredArchiveMember)
        var pieces: [String] = []
        var remaining = byteLimit

        if !plainEntries.isEmpty,
           let data = extractArchiveEntries(plainEntries, from: url, byteLimit: remaining),
           let text = decodePlainText(data), !text.isEmpty {
            pieces.append(text)
            remaining -= min(remaining, data.count)
        }

        for entry in structuredEntries where remaining > 0 {
            guard let data = extractArchiveEntries([entry], from: url, byteLimit: remaining) else {
                return nil
            }
            let extensionName = (entry as NSString).pathExtension.lowercased()
            let text: String?
            if extensionName == "pdf" {
                text = PDFDocument(data: data)?.string
            } else if let type = attributedDocumentTypes[extensionName] {
                var attributes: NSDictionary?
                text = try? NSAttributedString(
                    data: data,
                    options: [.documentType: type],
                    documentAttributes: &attributes
                ).string
            } else {
                text = decodePlainText(data)
            }
            if let text, !text.isEmpty { pieces.append(text) }
            remaining -= min(remaining, data.count)
        }

        let combined = pieces.joined(separator: "\n")
        return combined.isEmpty ? nil : combined
    }

    private static func decompressLZMA(_ data: Data, byteLimit: Int) -> Data? {
        guard !data.isEmpty, byteLimit > 0 else { return nil }
        let placeholder = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer { placeholder.deallocate() }
        var stream = compression_stream(
            dst_ptr: placeholder,
            dst_size: 0,
            src_ptr: UnsafePointer(placeholder),
            src_size: 0,
            state: nil
        )
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_LZMA)
                != COMPRESSION_STATUS_ERROR else { return nil }
        defer { compression_stream_destroy(&stream) }

        var output = Data()
        output.reserveCapacity(min(byteLimit, 1 * 1_024 * 1_024))
        let succeeded = data.withUnsafeBytes { input -> Bool in
            guard let baseAddress = input.bindMemory(to: UInt8.self).baseAddress else { return false }
            stream.src_ptr = baseAddress
            stream.src_size = data.count
            var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
            while true {
                let remaining = byteLimit - output.count
                guard remaining > 0 else { return false }
                let capacity = min(buffer.count, remaining)
                let status = buffer.withUnsafeMutableBytes { destination -> compression_status in
                    stream.dst_ptr = destination.bindMemory(to: UInt8.self).baseAddress!
                    stream.dst_size = capacity
                    return compression_stream_process(
                        &stream,
                        Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
                    )
                }
                let produced = capacity - stream.dst_size
                if produced > 0 { output.append(contentsOf: buffer.prefix(produced)) }
                if output.count > byteLimit { return false }
                switch status {
                case COMPRESSION_STATUS_END:
                    return stream.src_size == 0
                case COMPRESSION_STATUS_OK:
                    if produced == 0, stream.src_size == 0 { return false }
                default:
                    return false
                }
            }
        }
        return succeeded ? output : nil
    }

    private static func archiveEntries(in url: URL) -> [String]? {
        guard let result = LimitedProcess.run(
            executable: "/usr/bin/bsdtar",
            arguments: ["-tf", url.path],
            outputLimit: listingLimit,
            timeout: processTimeout
        ), result.status == 0, !result.wasLimited,
           let listing = String(data: result.output, encoding: .utf8) else { return nil }
        let entries = listing
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .newlines) }
        guard entries.allSatisfy({ $0.utf8.count <= 4_096 }) else { return nil }
        return entries
    }

    private static func extractArchiveEntries(
        _ entries: [String],
        from url: URL,
        byteLimit: Int
    ) -> Data? {
        guard !entries.isEmpty, byteLimit > 0 else { return nil }
        var output = Data()
        var offset = 0
        while offset < entries.count {
            var chunk: [String] = []
            var argumentBytes = 0
            while offset < entries.count, chunk.count < 128 {
                let entry = entries[offset]
                let addedBytes = entry.utf8.count + 1
                if !chunk.isEmpty, argumentBytes + addedBytes > 64 * 1_024 { break }
                chunk.append(entry)
                argumentBytes += addedBytes
                offset += 1
            }
            let remaining = byteLimit - output.count
            guard remaining > 0,
                  let result = LimitedProcess.run(
                    executable: "/usr/bin/bsdtar",
                    arguments: ["-xOf", url.path, "--"] + chunk,
                    outputLimit: remaining,
                    timeout: processTimeout
                  ), result.status == 0, !result.wasLimited else { return nil }
            output.append(result.output)
            if offset < entries.count, output.count < byteLimit {
                output.append(UInt8(ascii: "\n"))
            }
        }
        return output
    }

    private static func isPlainArchiveMember(_ entry: String) -> Bool {
        guard !entry.hasSuffix("/") else { return false }
        let name = (entry as NSString).lastPathComponent
        let lowerName = name.lowercased()
        let extensionName = (lowerName as NSString).pathExtension
        guard !nestedArchiveExtensions.contains(extensionName) else { return false }
        return plainTextExtensions.contains(extensionName)
            || commonTextNames.contains(lowerName)
            || commonTextNames.contains((lowerName as NSString).deletingPathExtension)
    }

    private static func isStructuredArchiveMember(_ entry: String) -> Bool {
        let extensionName = (entry as NSString).pathExtension.lowercased()
        return extensionName == "pdf" || attributedDocumentTypes[extensionName] != nil
    }

    private static func singleCompressedCommand(for lowerName: String) -> (executable: String, arguments: [String])? {
        if lowerName.hasSuffix(".gz") { return ("/usr/bin/gzip", ["-dc", "--"]) }
        if lowerName.hasSuffix(".bz2") { return ("/usr/bin/bzip2", ["-dc", "--"]) }
        return nil
    }

    private static func visibleXMLText(_ xml: String) -> String {
        var output = String()
        output.reserveCapacity(min(xml.utf8.count, 1_000_000))
        var inTag = false
        var entity = String()
        var inEntity = false
        for character in xml {
            if inEntity {
                if character == ";" {
                    switch entity {
                    case "amp": output.append("&")
                    case "lt": output.append("<")
                    case "gt": output.append(">")
                    case "quot": output.append("\"")
                    case "apos": output.append("'")
                    default:
                        output.append("&")
                        output.append(entity)
                        output.append(";")
                    }
                    entity.removeAll(keepingCapacity: true)
                    inEntity = false
                } else if entity.count < 16 {
                    entity.append(character)
                } else {
                    output.append("&")
                    output.append(entity)
                    entity.removeAll(keepingCapacity: true)
                    inEntity = false
                }
                continue
            }
            if character == "<" {
                inTag = true
                if output.last?.isWhitespace == false { output.append(" ") }
            } else if character == ">" {
                inTag = false
            } else if !inTag, character == "&" {
                inEntity = true
            } else if !inTag {
                output.append(character)
            }
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodePlainText(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        if data.prefix(binarySniffBytes).contains(0) {
            if data.starts(with: [0xFF, 0xFE, 0x00, 0x00])
                || data.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
                return String(data: data, encoding: .utf32)
            }
            if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
                return String(data: data, encoding: .utf16)
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1252)
            ?? String(data: data, encoding: .isoLatin1)
            ?? String(data: data, encoding: .macOSRoman)
    }

    @inline(__always)
    private static func containsASCII(
        _ bytes: [UInt8],
        needle: [UInt8],
        foldedNeedle: [UInt8],
        caseSensitive: Bool
    ) -> Bool {
        guard !needle.isEmpty, bytes.count >= needle.count else { return false }
        let lastStart = bytes.count - needle.count
        for start in 0...lastStart {
            var matches = true
            for offset in needle.indices {
                let byte = bytes[start + offset]
                if caseSensitive {
                    if byte != needle[offset] { matches = false; break }
                } else if asciiLowercased(byte) != foldedNeedle[offset] {
                    matches = false
                    break
                }
            }
            if matches { return true }
        }
        return false
    }

    @inline(__always)
    private static func asciiLowercased(_ byte: UInt8) -> UInt8 {
        (65...90).contains(byte) ? byte + 32 : byte
    }

    private static func temporaryURL(extension extensionName: String) -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenFind-Extraction.noindex", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(extensionName)
    }
}

private struct LimitedProcessResult {
    let output: Data
    let status: Int32
    let wasLimited: Bool
}

private enum LimitedProcess {
    static func run(
        executable: String,
        arguments: [String],
        outputLimit: Int,
        timeout: TimeInterval
    ) -> LimitedProcessResult? {
        guard outputLimit > 0 else { return nil }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }
        try? pipe.fileHandleForWriting.close()

        let descriptor = pipe.fileHandleForReading.fileDescriptor
        let oldFlags = fcntl(descriptor, F_GETFL)
        if oldFlags >= 0 { _ = fcntl(descriptor, F_SETFL, oldFlags | O_NONBLOCK) }

        var output = Data()
        output.reserveCapacity(min(outputLimit, 1 * 1_024 * 1_024))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        let deadline = Date().addingTimeInterval(timeout)
        var wasLimited = false

        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                let remaining = outputLimit - output.count
                if count > remaining {
                    if remaining > 0 { output.append(contentsOf: buffer.prefix(remaining)) }
                    wasLimited = true
                    stop(process)
                } else {
                    output.append(contentsOf: buffer.prefix(count))
                }
            } else if count == 0, !process.isRunning {
                break
            } else if count < 0, errno != EAGAIN, errno != EWOULDBLOCK {
                stop(process)
                wasLimited = true
            }

            if Task.isCancelled || Date() >= deadline {
                stop(process)
                wasLimited = true
            }
            if wasLimited, !process.isRunning { break }
            if count <= 0 { usleep(10_000) }
        }

        if process.isRunning { stop(process) }
        process.waitUntilExit()
        try? pipe.fileHandleForReading.close()
        return LimitedProcessResult(
            output: output,
            status: process.terminationStatus,
            wasLimited: wasLimited
        )
    }

    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let graceDeadline = Date().addingTimeInterval(0.2)
        while process.isRunning, Date() < graceDeadline { usleep(10_000) }
        if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
    }
}

import Foundation

/// A single match. Identity is the URL, which de-duplicates naturally.
struct SearchResult: Identifiable, Hashable, Sendable {
    var id: URL { url }
    /// Only the visible page needs Foundation URLs. Keeping one URL object for
    /// every match duplicates path storage and makes million-result searches
    /// retain gigabytes after the search has finished.
    var url: URL { URL(fileURLWithPath: path, isDirectory: isDirectory) }
    private let resolvedNode: ResolvedNode
    var name: String { resolvedNode.name }
    var path: String { resolvedNode.path }
    var resolvedIdentity: ResolvedNodeIdentity { resolvedNode.identity }
    var isPathDeferred: Bool { resolvedNode.isPathDeferred }
    var isDirectory: Bool { resolvedNode.isDirectory }
    var size: Int64 { resolvedNode.size }
    var modified: Date { resolvedNode.modifiedDate }
    var created: Date { resolvedNode.createdDate }
    /// True when the hit came from content matching, false for a name match.
    let matchedContent: Bool
    /// First matching line (trimmed) for content hits; nil for name hits.
    let contentPreview: String?

    init(
        name: String,
        path: String,
        isDirectory: Bool,
        size: Int64,
        modified: Date,
        created: Date,
        matchedContent: Bool,
        contentPreview: String?
    ) {
        resolvedNode = ResolvedNode(
            node: IndexedFileNode(
                name: name,
                parentIndex: -1,
                isDirectory: isDirectory,
                size: size,
                modifiedTime: modified.timeIntervalSinceReferenceDate,
                creationTime: created.timeIntervalSinceReferenceDate,
                isHiddenScope: false,
                isPackageDescendant: false
            ),
            path: path
        )
        self.matchedContent = matchedContent
        self.contentPreview = contentPreview
    }

    init(
        resolvedNode: ResolvedNode,
        matchedContent: Bool,
        contentPreview: String?
    ) {
        self.resolvedNode = resolvedNode
        self.matchedContent = matchedContent
        self.contentPreview = contentPreview
    }

    static func == (lhs: SearchResult, rhs: SearchResult) -> Bool {
        lhs.name == rhs.name
            && lhs.path == rhs.path
            && lhs.isDirectory == rhs.isDirectory
            && lhs.size == rhs.size
            && lhs.modified == rhs.modified
            && lhs.created == rhs.created
            && lhs.matchedContent == rhs.matchedContent
            && lhs.contentPreview == rhs.contentPreview
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(path)
        hasher.combine(isDirectory)
        hasher.combine(size)
        hasher.combine(modified)
        hasher.combine(created)
        hasher.combine(matchedContent)
        hasher.combine(contentPreview)
    }

    /// The parent directory path, shown as the result's secondary location text.
    var locationPath: String {
        (path as NSString).deletingLastPathComponent
    }
}

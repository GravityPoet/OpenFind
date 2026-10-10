import Foundation

public struct BrowserSearchRequest: Sendable {
    public let query: String
    public let scope: String?
    public let type: String?
    public let kind: String?
    public let limit: Int
    public let isStatus: Bool
}

public struct Hit: Decodable, Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let kind: String
    public let size: UInt64
    public let mtime: UInt64
    public let score: Int64
    public var metadataPending: Bool? = nil
    var url: URL { URL(fileURLWithPath: path, isDirectory: kind == "dir") }
    var name: String { (path as NSString).lastPathComponent }
    var imageKey: String { path + ":" + String(mtime) + ":" + String(metadataPending == true) }
    var parent: String { (path as NSString).deletingLastPathComponent.replacingOccurrences(of: NSHomeDirectory(), with: "~", options: .anchored) }

    public init(path: String, kind: String, size: UInt64, mtime: UInt64, score: Int64, metadataPending: Bool? = nil) {
        self.path = path; self.kind = kind; self.size = size
        self.mtime = mtime; self.score = score; self.metadataPending = metadataPending
    }
}

public struct Reply: Decodable, Sendable {
    public let ok: Bool
    public let error: String?
    public let hits: [Hit]?
    public let took_us: UInt64?
    public let entries: Int?
    public let full_disk_access: Bool?

    public init(ok: Bool, error: String? = nil, hits: [Hit]? = nil, took_us: UInt64? = nil, entries: Int? = nil, full_disk_access: Bool? = nil) {
        self.ok = ok; self.error = error; self.hits = hits
        self.took_us = took_us; self.entries = entries; self.full_disk_access = full_disk_access
    }
}

protocol SearchService: Sendable {
    func request(_ fields: [String: Any]) async throws -> Reply
}

public enum BrowserSearchProvider {
    public typealias Handler = @Sendable (BrowserSearchRequest) async throws -> Reply
    private static let lock = NSLock()
    private static var handler: Handler?

    public static func configure(_ handler: @escaping Handler) {
        lock.lock(); Self.handler = handler; lock.unlock()
    }

    fileprivate static func current() -> Handler? {
        lock.lock(); defer { lock.unlock() }; return handler
    }
}

/// In-process adapter to OpenFind's existing index. No child or daemon.
final class Engine: SearchService, @unchecked Sendable {
    private let handler: BrowserSearchProvider.Handler?
    init(handler: BrowserSearchProvider.Handler? = nil) { self.handler = handler }

    enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
    }

    func request(_ fields: [String: Any]) async throws -> Reply {
        try Task.checkCancellation()
        guard let handler = handler ?? BrowserSearchProvider.current() else {
            return Reply(ok: false, error: "Search index is not ready.")
        }
        let request = BrowserSearchRequest(
            query: fields["q"] as? String ?? "", scope: fields["in"] as? String,
            type: fields["type"] as? String, kind: fields["kind"] as? String,
            limit: max(1, fields["limit"] as? Int ?? 500), isStatus: fields["op"] as? String == "status"
        )
        return try await handler(request)
    }
}

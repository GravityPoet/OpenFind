import CoreServices
import Foundation

enum FileSystemIndexRefresh: Equatable, Sendable {
    case exact(String)
    case subtree(String)
    case directoryMetadata(String)
}

struct FileSystemEvent: Sendable {
    let path: String?
    let eventID: UInt64
    let flags: UInt32
    let receivedAt: Date
    let requiresFullRescan: Bool

    var indexRefresh: FileSystemIndexRefresh? {
        guard let path else { return nil }
        let canonicalPath = SearchPath.canonicalAliasPath(path)
        // Full-history FSEvents can emit document-ID transition records such
        // as `/.docid/16777233/changed/.../src=...,dst=...`. They are not
        // filesystem paths (there is no `/.docid` tree to index), so treating
        // each record as a missing subtree creates an ever-growing retry log.
        guard !Self.isSyntheticDocumentIDPath(canonicalPath) else { return nil }
        let eventFlags = FSEventStreamEventFlags(flags)
        let isFileLike =
            (eventFlags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile)) != 0
            || (eventFlags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsSymlink)) != 0
        let isDirectory = (eventFlags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir)) != 0

        if (eventFlags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed)) != 0 {
            // With file-level FSEvents, a rename is delivered for both the old
            // and new path unless the stream also reports a dropped-event
            // condition. Reconcile those two paths directly: files need two
            // exact updates, while a moved directory needs its old and new
            // subtrees replaced. Unknown/coarse records keep the conservative
            // parent fallback so completeness never depends on a type guess.
            if isFileLike { return .exact(canonicalPath) }
            if isDirectory { return .subtree(canonicalPath) }
            let parent = (canonicalPath as NSString).deletingLastPathComponent
            return .subtree(parent.isEmpty ? "/" : parent)
        }
        if isFileLike {
            return .exact(canonicalPath)
        }

        if isDirectory {
            let structuralFlags = FSEventStreamEventFlags(
                kFSEventStreamEventFlagItemCreated
                    | kFSEventStreamEventFlagItemRemoved
                    | kFSEventStreamEventFlagItemCloned
            )
            if (eventFlags & structuralFlags) != 0 {
                return .subtree(canonicalPath)
            }

            let metadataFlags = FSEventStreamEventFlags(
                kFSEventStreamEventFlagItemInodeMetaMod
                    | kFSEventStreamEventFlagItemChangeOwner
                    | kFSEventStreamEventFlagItemXattrMod
                    | kFSEventStreamEventFlagItemFinderInfoMod
            )
            if (eventFlags & metadataFlags) != 0 {
                return .directoryMetadata(canonicalPath)
            }
            return .exact(canonicalPath)
        }

        // A history/coarse event without item flags can represent arbitrary
        // descendant changes, so only this fallback requires a subtree scan.
        return .subtree(canonicalPath)
    }

    static func isSyntheticDocumentIDPath(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count == 5,
              components[0] == ".docid",
              UInt64(components[1]) != nil,
              components[2] == "changed",
              UInt64(components[3]) != nil else { return false }

        let transition = components[4]
        guard transition.hasPrefix("src="),
              let separator = transition.range(of: ",dst=") else { return false }
        let source = transition[transition.index(transition.startIndex, offsetBy: 4)..<separator.lowerBound]
        let destination = transition[separator.upperBound...]
        return UInt64(source) != nil && UInt64(destination) != nil
    }
}

final class FileSystemEventWatcher: @unchecked Sendable {
    private final class CallbackBox: @unchecked Sendable {
        let handler: @Sendable ([FileSystemEvent]) async -> Void
        private let lock = NSLock()
        private var tail: Task<Void, Never>?
        private var cancelled = false

        init(handler: @escaping @Sendable ([FileSystemEvent]) async -> Void) {
            self.handler = handler
        }

        func enqueue(_ events: [FileSystemEvent]) {
            lock.lock()
            guard !cancelled else {
                lock.unlock()
                return
            }
            let previous = tail
            let handler = self.handler
            tail = Task { [weak self] in
                await previous?.value
                guard !Task.isCancelled, self?.isCancelled == false else { return }
                await handler(events)
            }
            lock.unlock()
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let task = tail
            tail = nil
            lock.unlock()
            task?.cancel()
        }

        private var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }
    }

    private static let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, eventFlags, eventIDs in
        guard let info else { return }
        let box = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()
        let array = unsafeBitCast(eventPaths, to: NSArray.self)
        var events: [FileSystemEvent] = []
        events.reserveCapacity(numEvents)
        let receivedAt = Date()

        for index in 0..<numEvents {
            let flags = eventFlags[index]
            let isHistoryDone = (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone)) != 0
            let requiresFullRescan =
                (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)) != 0 ||
                (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped)) != 0 ||
                (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped)) != 0 ||
                (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)) != 0 ||
                (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped)) != 0

            let item = array[index]
            let path = FileSystemEventWatcher.eventPath(from: item, isHistoryDone: isHistoryDone)
            events.append(FileSystemEvent(
                path: path,
                eventID: UInt64(eventIDs[index]),
                flags: UInt32(flags),
                receivedAt: receivedAt,
                requiresFullRescan: requiresFullRescan
            ))
        }

        box.enqueue(events)
    }

    private let queue = DispatchQueue(label: "OpenFind.FileSystemEventWatcher", qos: .utility)
    private var stream: FSEventStreamRef?
    private var callbackBox: CallbackBox?

    static func currentEventID() -> UInt64 {
        UInt64(FSEventsGetCurrentEventId())
    }

    static func eventPath(from item: Any, isHistoryDone: Bool) -> String? {
        guard !isHistoryDone else { return nil }
        if let extendedPath = (item as? NSDictionary)?["path"] as? String {
            return extendedPath
        }
        return item as? String
    }

    static func creationFlags(fileEvents: Bool) -> UInt32 {
        var flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagUseExtendedData
            | kFSEventStreamCreateFlagFullHistory
            | kFSEventStreamCreateFlagNoDefer
            | kFSEventStreamCreateFlagWatchRoot
            | kFSEventStreamCreateFlagMarkSelf
        )
        if fileEvents {
            flags |= UInt32(kFSEventStreamCreateFlagFileEvents)
        }
        return flags
    }

    init?(
        paths: [String],
        sinceEventID: UInt64? = nil,
        fileEvents: Bool = true,
        handler: @escaping @Sendable ([FileSystemEvent]) async -> Void
    ) {
        guard !paths.isEmpty else { return nil }

        let box = CallbackBox(handler: handler)
        callbackBox = box
        let retainedBox = Unmanaged.passRetained(box)
        var context = FSEventStreamContext(
            version: 0,
            info: retainedBox.toOpaque(),
            retain: nil,
            release: { info in
                guard let info else { return }
                Unmanaged<CallbackBox>.fromOpaque(info).release()
            },
            copyDescription: nil
        )

        let flags = Self.creationFlags(fileEvents: fileEvents)

        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(sinceEventID ?? UInt64(kFSEventStreamEventIdSinceNow)),
            0.5,
            flags
        ) else {
            retainedBox.release()
            return nil
        }

        stream = created
        FSEventStreamSetDispatchQueue(created, queue)

        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            stream = nil
            return nil
        }
    }

    func stop() {
        callbackBox?.cancel()
        callbackBox = nil
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        self.stream = nil
    }

    deinit {
        stop()
    }
}

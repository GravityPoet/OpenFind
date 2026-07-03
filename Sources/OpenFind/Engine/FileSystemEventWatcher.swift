import CoreServices
import Foundation

struct FileSystemEvent: Sendable {
    let path: String?
    let eventID: UInt64
    let requiresFullRescan: Bool
}

final class FileSystemEventWatcher: @unchecked Sendable {
    private final class CallbackBox {
        let handler: @Sendable ([FileSystemEvent]) -> Void

        init(handler: @escaping @Sendable ([FileSystemEvent]) -> Void) {
            self.handler = handler
        }
    }

    private static let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, eventFlags, eventIDs in
        guard let info else { return }
        let box = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()
        let array = unsafeBitCast(eventPaths, to: NSArray.self)
        var events: [FileSystemEvent] = []
        events.reserveCapacity(numEvents)

        for index in 0..<numEvents {
            let flags = eventFlags[index]
            let isHistoryDone = (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone)) != 0
            let requiresFullRescan =
                (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)) != 0 ||
                (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped)) != 0 ||
                (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped)) != 0 ||
                (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)) != 0 ||
                (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped)) != 0

            let path = isHistoryDone ? nil : array[index] as? String
            events.append(FileSystemEvent(
                path: path,
                eventID: UInt64(eventIDs[index]),
                requiresFullRescan: requiresFullRescan
            ))
        }

        box.handler(events)
    }

    private let queue = DispatchQueue(label: "OpenFind.FileSystemEventWatcher", qos: .utility)
    private var stream: FSEventStreamRef?

    static func currentEventID() -> UInt64 {
        UInt64(FSEventsGetCurrentEventId())
    }

    init?(paths: [String], sinceEventID: UInt64? = nil, handler: @escaping @Sendable ([FileSystemEvent]) -> Void) {
        guard !paths.isEmpty else { return nil }

        let box = CallbackBox(handler: handler)
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

        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagNoDefer
            | kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagWatchRoot
        )

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
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        self.stream = nil
    }

    deinit {
        stop()
    }
}

import CoreServices
import Foundation

final class FileSystemEventWatcher: @unchecked Sendable {
    private final class CallbackBox {
        let handler: @Sendable ([String]) -> Void

        init(handler: @escaping @Sendable ([String]) -> Void) {
            self.handler = handler
        }
    }

    private static let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
        guard let info else { return }
        let box = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()
        let array = unsafeBitCast(eventPaths, to: NSArray.self)
        let paths = array.compactMap { $0 as? String }
        box.handler(paths)
    }

    private let queue = DispatchQueue(label: "OpenFind.FileSystemEventWatcher", qos: .utility)
    private var stream: FSEventStreamRef?

    init?(paths: [String], handler: @escaping @Sendable ([String]) -> Void) {
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
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
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

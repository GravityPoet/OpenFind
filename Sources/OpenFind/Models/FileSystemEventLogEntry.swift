import CoreServices
import Foundation

struct FileSystemEventLogEntry: Identifiable, Hashable, Sendable {
    let id: Int64
    let receivedAt: Date
    let eventID: UInt64
    let flags: UInt32
    let path: String?
    let name: String
    let locationPath: String
    let normalizedPath: String
    let sortKey: String
    let localizedEventKeys: [String]
    let matchesQuery: String

    init(
        id: Int64,
        receivedAt: Date,
        eventID: UInt64,
        flags: UInt32,
        path: String?
    ) {
        self.id = id
        self.receivedAt = receivedAt
        self.eventID = eventID
        self.flags = flags
        self.path = path

        let normalizedPath = path ?? ""
        self.normalizedPath = normalizedPath
        if normalizedPath.isEmpty {
            name = "—"
            locationPath = "—"
        } else {
            name = (normalizedPath as NSString).lastPathComponent
            let parent = (normalizedPath as NSString).deletingLastPathComponent
            locationPath = parent.isEmpty ? "/" : parent
        }

        var keys: [String] = []
        let flag = FSEventStreamEventFlags(flags)

        Self.append("Created", if: flag, contains: kFSEventStreamEventFlagItemCreated, into: &keys)
        Self.append("Removed", if: flag, contains: kFSEventStreamEventFlagItemRemoved, into: &keys)
        Self.append("Renamed", if: flag, contains: kFSEventStreamEventFlagItemRenamed, into: &keys)
        Self.append("Modified", if: flag, contains: kFSEventStreamEventFlagItemModified, into: &keys)
        Self.append("InodeMetaMod", if: flag, contains: kFSEventStreamEventFlagItemInodeMetaMod, into: &keys)
        Self.append("FinderInfoMod", if: flag, contains: kFSEventStreamEventFlagItemFinderInfoMod, into: &keys)
        Self.append("ChangeOwner", if: flag, contains: kFSEventStreamEventFlagItemChangeOwner, into: &keys)
        Self.append("XattrMod", if: flag, contains: kFSEventStreamEventFlagItemXattrMod, into: &keys)
        Self.append("Cloned", if: flag, contains: kFSEventStreamEventFlagItemCloned, into: &keys)
        Self.append("MustScanSubDirs", if: flag, contains: kFSEventStreamEventFlagMustScanSubDirs, into: &keys)
        Self.append("EventsDropped", if: flag, contains: kFSEventStreamEventFlagUserDropped, into: &keys)
        Self.append("EventsDropped", if: flag, contains: kFSEventStreamEventFlagKernelDropped, into: &keys)
        Self.append("RootChanged", if: flag, contains: kFSEventStreamEventFlagRootChanged, into: &keys)
        Self.append("HistoryDone", if: flag, contains: kFSEventStreamEventFlagHistoryDone, into: &keys)

        if keys.isEmpty {
            keys.append("Changed")
        }
        localizedEventKeys = Array(NSOrderedSet(array: keys)) as? [String] ?? keys
        sortKey = localizedEventKeys.joined(separator: " ")
        matchesQuery = ([name, locationPath, normalizedPath, sortKey] + localizedEventKeys)
            .joined(separator: " ")
            .lowercased()
    }

    private static func append(
        _ key: String,
        if flag: FSEventStreamEventFlags,
        contains expected: Int,
        into keys: inout [String]
    ) {
        if (flag & FSEventStreamEventFlags(expected)) != 0 {
            keys.append(key)
        }
    }
}

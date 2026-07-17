import Darwin
import Foundation

/// One no-follow directory entry returned by `getattrlistbulk(2)`.
///
/// The full scanner uses this only as a metadata transport. Any unsupported
/// attribute or malformed record makes the whole directory fall back to the
/// existing Foundation path, so the optimization cannot silently narrow the
/// index or invent metadata.
struct BulkDirectoryEntry: Sendable, Equatable {
    let name: String
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let size: Int64
    let modifiedTime: Double
    let creationTime: Double
    let isHidden: Bool
}

/// Minimal directory-entry topology used by the query-ready index stage.
/// Size and timestamps are intentionally absent so APFS can return a smaller
/// record and the first pass can publish complete names and paths sooner.
struct BulkDirectoryTopologyEntry: Sendable, Equatable {
    let name: String
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let isHidden: Bool
}

struct BulkDirectoryIdentity: Hashable, Sendable {
    let device: UInt64
    let inode: UInt64
}

enum BulkDirectoryReader {
    private static let bufferSize = 256 * 1_024
    private static let unixToReferenceDate = 978_307_200.0

    /// Returns `nil` when this filesystem cannot provide an equivalent record.
    /// Operational failures are thrown so the caller preserves its retry and
    /// unavailable-path behavior.
    static func read(
        path: String,
        claimIdentity: (BulkDirectoryIdentity) -> Bool = { _ in true }
    ) throws -> [BulkDirectoryEntry]? {
        let descriptor = path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw posixError(errno) }
        defer { close(descriptor) }

        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw posixError(errno) }
        let identity = BulkDirectoryIdentity(
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino)
        )
        // APFS firmlinks can expose an already-scanned directory through a
        // different textual path. Claim the opened directory identity before
        // reading any entries so those aliases cannot form traversal cycles.
        guard claimIdentity(identity) else { return [] }

        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = ATTR_CMN_RETURNED_ATTRS
            | UInt32(ATTR_CMN_NAME)
            | UInt32(ATTR_CMN_OBJTYPE)
            | UInt32(ATTR_CMN_CRTIME)
            | UInt32(ATTR_CMN_MODTIME)
            | UInt32(ATTR_CMN_FLAGS)
        attributes.fileattr = UInt32(ATTR_FILE_DATALENGTH)

        var storage = [UInt8](repeating: 0, count: bufferSize)
        var entries: [BulkDirectoryEntry] = []
        entries.reserveCapacity(256)

        while true {
            let count = storage.withUnsafeMutableBytes { buffer in
                getattrlistbulk(
                    descriptor,
                    &attributes,
                    buffer.baseAddress!,
                    buffer.count,
                    UInt64(FSOPT_PACK_INVAL_ATTRS)
                )
            }
            if count == 0 { return entries }
            if count < 0 {
                let code = errno
                if code == EINVAL || code == ENOTSUP || code == ENOSYS {
                    return nil
                }
                throw posixError(code)
            }

            guard let batch = storage.withUnsafeBytes({ buffer in
                parse(buffer: buffer, count: Int(count))
            }) else {
                return nil
            }
            entries.append(contentsOf: batch)
        }
    }

    /// Returns the lossless name/type/visibility subset needed before metadata
    /// enrichment. `nil` retains the same Foundation fallback contract as the
    /// full metadata reader; operational failures remain throwable.
    static func readTopology(
        path: String,
        claimIdentity: (BulkDirectoryIdentity) -> Bool = { _ in true }
    ) throws -> [BulkDirectoryTopologyEntry]? {
        let descriptor = path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw posixError(errno) }
        defer { close(descriptor) }

        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw posixError(errno) }
        let identity = BulkDirectoryIdentity(
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino)
        )
        guard claimIdentity(identity) else { return [] }

        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = ATTR_CMN_RETURNED_ATTRS
            | UInt32(ATTR_CMN_NAME)
            | UInt32(ATTR_CMN_OBJTYPE)
            | UInt32(ATTR_CMN_FLAGS)

        var storage = [UInt8](repeating: 0, count: bufferSize)
        var entries: [BulkDirectoryTopologyEntry] = []
        entries.reserveCapacity(256)

        while true {
            let count = storage.withUnsafeMutableBytes { buffer in
                getattrlistbulk(
                    descriptor,
                    &attributes,
                    buffer.baseAddress!,
                    buffer.count,
                    UInt64(FSOPT_PACK_INVAL_ATTRS)
                )
            }
            if count == 0 { return entries }
            if count < 0 {
                let code = errno
                if code == EINVAL || code == ENOTSUP || code == ENOSYS {
                    return nil
                }
                throw posixError(code)
            }

            guard let batch = storage.withUnsafeBytes({ buffer in
                parseTopology(buffer: buffer, count: Int(count))
            }) else {
                return nil
            }
            entries.append(contentsOf: batch)
        }
    }

    private static func parse(
        buffer: UnsafeRawBufferPointer,
        count: Int
    ) -> [BulkDirectoryEntry]? {
        guard let baseAddress = buffer.baseAddress else { return nil }
        var result: [BulkDirectoryEntry] = []
        result.reserveCapacity(count)
        var recordOffset = 0

        for _ in 0..<count {
            guard recordOffset <= buffer.count - MemoryLayout<UInt32>.size else { return nil }
            let record = baseAddress.advanced(by: recordOffset)
            let recordLength = Int(load(record, as: UInt32.self))
            guard recordLength >= 80,
                  recordLength.isMultiple(of: 8),
                  recordOffset <= buffer.count - recordLength else {
                return nil
            }

            var fieldOffset = MemoryLayout<UInt32>.size
            let returned = load(
                record.advanced(by: fieldOffset),
                as: attribute_set_t.self
            )
            fieldOffset += MemoryLayout<attribute_set_t>.size

            let requiredCommon = UInt32(ATTR_CMN_NAME)
                | UInt32(ATTR_CMN_OBJTYPE)
                | UInt32(ATTR_CMN_MODTIME)
                | UInt32(ATTR_CMN_FLAGS)
            guard returned.commonattr & requiredCommon == requiredCommon else { return nil }

            let nameReferenceOffset = fieldOffset
            let nameReference = load(
                record.advanced(by: fieldOffset),
                as: attrreference_t.self
            )
            fieldOffset += MemoryLayout<attrreference_t>.size

            let objectType = load(
                record.advanced(by: fieldOffset),
                as: fsobj_type_t.self
            )
            fieldOffset += MemoryLayout<fsobj_type_t>.size

            let creation = load(
                record.advanced(by: fieldOffset),
                as: timespec.self
            )
            fieldOffset += MemoryLayout<timespec>.size
            let modification = load(
                record.advanced(by: fieldOffset),
                as: timespec.self
            )
            fieldOffset += MemoryLayout<timespec>.size
            let flags = load(
                record.advanced(by: fieldOffset),
                as: UInt32.self
            )
            fieldOffset += MemoryLayout<UInt32>.size
            let dataLength = load(
                record.advanced(by: fieldOffset),
                as: Int64.self
            )

            let nameStart = nameReferenceOffset + Int(nameReference.attr_dataoffset)
            let nameLength = Int(nameReference.attr_length)
            guard nameLength > 1,
                  nameStart >= 0,
                  nameStart <= recordLength - nameLength else {
                return nil
            }
            let nameBuffer = UnsafeRawBufferPointer(
                start: record.advanced(by: nameStart),
                count: nameLength
            )
            guard nameBuffer[nameLength - 1] == 0,
                  let name = String(
                    bytes: nameBuffer.dropLast(),
                    encoding: .utf8
                  ),
                  name != ".",
                  name != "..",
                  !name.contains("/") else {
                return nil
            }

            let isDirectory = objectType == UInt32(VDIR.rawValue)
            let isSymbolicLink = objectType == UInt32(VLNK.rawValue)
            let hasFileLength = returned.fileattr & UInt32(ATTR_FILE_DATALENGTH) != 0
            guard isDirectory || hasFileLength else { return nil }
            guard let modifiedTime = referenceTime(modification) else { return nil }
            let creationTime: Double
            if returned.commonattr & UInt32(ATTR_CMN_CRTIME) != 0 {
                guard let value = referenceTime(creation) else { return nil }
                creationTime = value
            } else {
                creationTime = modifiedTime
            }

            result.append(BulkDirectoryEntry(
                name: name,
                isDirectory: isDirectory,
                isSymbolicLink: isSymbolicLink,
                size: isDirectory ? 0 : max(0, dataLength),
                modifiedTime: modifiedTime,
                creationTime: creationTime,
                isHidden: name.hasPrefix(".") || flags & UInt32(UF_HIDDEN) != 0
            ))
            recordOffset += recordLength
        }

        return result
    }

    private static func parseTopology(
        buffer: UnsafeRawBufferPointer,
        count: Int
    ) -> [BulkDirectoryTopologyEntry]? {
        guard let baseAddress = buffer.baseAddress else { return nil }
        let minimumRecordLength = MemoryLayout<UInt32>.size
            + MemoryLayout<attribute_set_t>.size
            + MemoryLayout<attrreference_t>.size
            + MemoryLayout<fsobj_type_t>.size
            + MemoryLayout<UInt32>.size
            + 2
        var result: [BulkDirectoryTopologyEntry] = []
        result.reserveCapacity(count)
        var recordOffset = 0

        for _ in 0..<count {
            guard recordOffset <= buffer.count - MemoryLayout<UInt32>.size else { return nil }
            let record = baseAddress.advanced(by: recordOffset)
            let recordLength = Int(load(record, as: UInt32.self))
            guard recordLength >= minimumRecordLength,
                  recordLength.isMultiple(of: 8),
                  recordOffset <= buffer.count - recordLength else {
                return nil
            }

            var fieldOffset = MemoryLayout<UInt32>.size
            let returned = load(record.advanced(by: fieldOffset), as: attribute_set_t.self)
            fieldOffset += MemoryLayout<attribute_set_t>.size
            let requiredCommon = UInt32(ATTR_CMN_NAME)
                | UInt32(ATTR_CMN_OBJTYPE)
                | UInt32(ATTR_CMN_FLAGS)
            guard returned.commonattr & requiredCommon == requiredCommon else { return nil }

            let nameReferenceOffset = fieldOffset
            let nameReference = load(record.advanced(by: fieldOffset), as: attrreference_t.self)
            fieldOffset += MemoryLayout<attrreference_t>.size
            let objectType = load(record.advanced(by: fieldOffset), as: fsobj_type_t.self)
            fieldOffset += MemoryLayout<fsobj_type_t>.size
            let flags = load(record.advanced(by: fieldOffset), as: UInt32.self)

            let nameStart = nameReferenceOffset + Int(nameReference.attr_dataoffset)
            let nameLength = Int(nameReference.attr_length)
            guard nameLength > 1,
                  nameStart >= 0,
                  nameStart <= recordLength - nameLength else {
                return nil
            }
            let nameBuffer = UnsafeRawBufferPointer(
                start: record.advanced(by: nameStart),
                count: nameLength
            )
            guard nameBuffer[nameLength - 1] == 0,
                  let name = String(bytes: nameBuffer.dropLast(), encoding: .utf8),
                  name != ".",
                  name != "..",
                  !name.contains("/") else {
                return nil
            }

            result.append(BulkDirectoryTopologyEntry(
                name: name,
                isDirectory: objectType == UInt32(VDIR.rawValue),
                isSymbolicLink: objectType == UInt32(VLNK.rawValue),
                isHidden: name.hasPrefix(".") || flags & UInt32(UF_HIDDEN) != 0
            ))
            recordOffset += recordLength
        }

        return result
    }

    private static func referenceTime(_ value: timespec) -> Double? {
        guard value.tv_nsec >= 0, value.tv_nsec < 1_000_000_000 else { return nil }
        return Double(value.tv_sec)
            + Double(value.tv_nsec) / 1_000_000_000.0
            - unixToReferenceDate
    }

    @inline(__always)
    private static func load<T>(
        _ pointer: UnsafeRawPointer,
        as type: T.Type
    ) -> T {
        pointer.loadUnaligned(as: type)
    }

    private static func posixError(_ code: Int32) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}

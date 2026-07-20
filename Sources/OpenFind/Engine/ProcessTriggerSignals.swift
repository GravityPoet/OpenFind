import Darwin
import Foundation

enum ProcessTriggerSignals {
    private static let maximumProcessCount = 131_072
    private static let maximumNameBytes = 4_096

    /// Returns the same process-name class that Amphetamine's optional
    /// `ps ax -c` discovery script exposes, without invoking a shell or
    /// requiring a separately installed script in a direct build.
    static func currentNames() -> Set<String> {
        let estimate = max(64, Int(proc_listallpids(nil, 0)))
        var capacity = min(maximumProcessCount, estimate + 64)

        while true {
            var processIDs = [pid_t](repeating: 0, count: capacity)
            let count = proc_listallpids(
                &processIDs,
                Int32(processIDs.count * MemoryLayout<pid_t>.stride)
            )
            guard count > 0 else { return [] }

            if count >= capacity, capacity < maximumProcessCount {
                capacity = min(maximumProcessCount, capacity * 2)
                continue
            }

            return Set(processIDs.prefix(min(Int(count), processIDs.count)).compactMap(processName))
        }
    }

    private static func processName(processID: pid_t) -> String? {
        guard processID > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: maximumNameBytes)
        guard proc_name(processID, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let value = String(decoding: bytes, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.utf8.count <= 1_024,
              value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        return value
    }
}

import Foundation

enum SearchPermissions {
    enum ProbeResult {
        case accessible
        case missing
        case denied
    }

    static func hasFullDiskAccess() -> Bool {
        hasFullDiskAccess(probe: probeProtectedLocation)
    }

    /// Full Disk Access has no supported read API. Probe the TCC databases
    /// themselves: directory enumeration under Mail, Messages, or Safari can
    /// succeed even when their contents remain protected, which would produce
    /// a false positive and let whole-Mac indexing trigger folder prompts.
    static func hasFullDiskAccess(
        probe: (URL) -> ProbeResult
    ) -> Bool {
        for url in protectedProbeURLs {
            switch probe(url) {
            case .accessible:
                return true
            case .missing, .denied:
                continue
            }
        }
        return false
    }

    private static var protectedProbeURLs: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            URL(
                fileURLWithPath: "/Library/Application Support/com.apple.TCC/TCC.db",
                isDirectory: false
            ),
            home.appendingPathComponent(
                "Library/Application Support/com.apple.TCC/TCC.db",
                isDirectory: false
            ),
        ]
    }

    private static func probeProtectedLocation(_ url: URL) -> ProbeResult {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            try handle.close()
            return .accessible
        } catch {
            return isMissing(error) ? .missing : .denied
        }
    }

    private static func isMissing(_ error: Error) -> Bool {
        var current = error as NSError
        while true {
            if current.domain == NSCocoaErrorDomain,
               current.code == NSFileNoSuchFileError
                || current.code == NSFileReadNoSuchFileError {
                return true
            }
            if current.domain == NSPOSIXErrorDomain, current.code == Int(ENOENT) {
                return true
            }
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError,
                  underlying !== current else {
                return false
            }
            current = underlying
        }
    }
}

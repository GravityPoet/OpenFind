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

    /// Full Disk Access has no supported read API. Probe several locations
    /// macOS protects with the same TCC grant instead of treating one missing
    /// or temporarily unavailable app-data folder as a definitive denial.
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
            home.appendingPathComponent("Library/Mail", isDirectory: true),
            home.appendingPathComponent("Library/Messages", isDirectory: true),
            home.appendingPathComponent("Library/Safari", isDirectory: true),
            URL(
                fileURLWithPath: "/Library/Application Support/com.apple.TCC/TCC.db",
                isDirectory: false
            ),
        ]
    }

    private static func probeProtectedLocation(_ url: URL) -> ProbeResult {
        do {
            if url.hasDirectoryPath {
                _ = try FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: nil,
                    options: [.skipsSubdirectoryDescendants]
                )
            } else {
                let handle = try FileHandle(forReadingFrom: url)
                try handle.close()
            }
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

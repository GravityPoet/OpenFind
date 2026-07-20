import Foundation

@MainActor
protocol FileDownloadConditionMonitoring: AnyObject {
    func isMonitorable(_ url: URL) -> Bool
    func observe(
        _ url: URL,
        inactivityTimeout: TimeInterval,
        onStalled: @escaping @MainActor () -> Void
    ) -> any SessionConditionObservation
}

@MainActor
final class PollingFileDownloadConditionMonitor: FileDownloadConditionMonitoring {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func isMonitorable(_ url: URL) -> Bool {
        guard url.isFileURL,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey]) else {
            return false
        }
        return values.isRegularFile == true && values.isReadable == true
    }

    func observe(
        _ url: URL,
        inactivityTimeout: TimeInterval,
        onStalled: @escaping @MainActor () -> Void
    ) -> any SessionConditionObservation {
        PollingFileDownloadObservation(
            url: url,
            inactivityTimeout: inactivityTimeout,
            fileManager: fileManager,
            onStalled: onStalled
        )
    }
}

@MainActor
private final class PollingFileDownloadObservation: SessionConditionObservation {
    private struct Snapshot: Equatable {
        let size: Int64
        let modifiedAt: Date?
    }

    private var task: Task<Void, Never>?

    init(
        url: URL,
        inactivityTimeout: TimeInterval,
        fileManager: FileManager,
        onStalled: @escaping @MainActor () -> Void
    ) {
        let interval = min(2, max(0.01, inactivityTimeout / 4))
        task = Task { @MainActor in
            let clock = ContinuousClock()
            var lastChange = clock.now
            var previous = Self.snapshot(url: url, fileManager: fileManager)
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch {
                    return
                }
                guard let current = Self.snapshot(url: url, fileManager: fileManager) else {
                    onStalled()
                    return
                }
                if current != previous {
                    previous = current
                    lastChange = clock.now
                    continue
                }
                if lastChange.duration(to: clock.now) >= .seconds(inactivityTimeout) {
                    onStalled()
                    return
                }
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    private static func snapshot(url: URL, fileManager: FileManager) -> Snapshot? {
        guard fileManager.fileExists(atPath: url.path),
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return nil }
        return Snapshot(
            size: size.int64Value,
            modifiedAt: attributes[.modificationDate] as? Date
        )
    }
}

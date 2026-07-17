import Darwin
import Foundation

enum ProcessMemoryReclaimer {
    static func releaseUnusedPages() {
        _ = malloc_zone_pressure_relief(malloc_default_zone(), 0)
    }

    static func schedule(after delay: Duration = .milliseconds(250)) {
        Task.detached(priority: .background) {
            try? await Task.sleep(for: delay)
            releaseUnusedPages()
        }
    }
}

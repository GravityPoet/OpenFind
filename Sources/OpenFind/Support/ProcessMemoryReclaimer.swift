import Darwin
import Foundation

enum ProcessMemoryReclaimer {
    static func releaseUnusedPages() {
        // Passing nil asks libmalloc to inspect every zone. This matters for
        // framework and Swift allocations that are not owned by the default
        // zone, while retaining the same best-effort semantics.
        _ = malloc_zone_pressure_relief(nil, 0)
    }

    static func schedule(after delay: Duration = .milliseconds(250)) {
        Task.detached(priority: .background) {
            try? await Task.sleep(for: delay)
            releaseUnusedPages()
        }
    }
}

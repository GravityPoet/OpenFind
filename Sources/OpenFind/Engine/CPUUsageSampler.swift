import Darwin
import Foundation

final class CPUUsageSampler {
    private var previous: (active: UInt64, total: UInt64)?

    func sample() -> Double? {
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size
        )
        let status = withUnsafeMutablePointer(to: &load) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }

        let user = UInt64(load.cpu_ticks.0)
        let system = UInt64(load.cpu_ticks.1)
        let idle = UInt64(load.cpu_ticks.2)
        let nice = UInt64(load.cpu_ticks.3)
        let active = user + system + nice
        let total = active + idle
        defer { previous = (active, total) }
        guard let previous, total > previous.total else { return nil }
        let activeDelta = active >= previous.active ? active - previous.active : 0
        let totalDelta = total - previous.total
        guard totalDelta > 0 else { return nil }
        return min(100, max(0, Double(activeDelta) / Double(totalDelta) * 100))
    }
}

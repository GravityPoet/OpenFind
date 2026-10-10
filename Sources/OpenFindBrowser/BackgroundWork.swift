// Adapted from FinderSearch (MIT), commit 021ad61679fbb1c1f18f9dc57a7d1bbc6883863e.
import Foundation

/// Run blocking work away from the main actor and forward caller cancellation.
enum BackgroundWork {
    static func run<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try operation()
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

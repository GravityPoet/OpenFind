import Foundation

@MainActor
final class AwakeSessionOperationGate {
    private var occupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var isOccupied: Bool { occupied }

    func enter() async {
        guard occupied else {
            occupied = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func leave() {
        guard !waiters.isEmpty else {
            occupied = false
            return
        }
        waiters.removeFirst().resume()
    }
}

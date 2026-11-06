import Foundation

/// A running restoration tile finishes, then waiting translation goes first.
/// Cancellation removes waiters rather than accumulating work while dragging.
actor InferenceScheduler {
    enum Priority: Sendable { case translation, refinement }
    private struct Waiter {
        let id: UUID
        let priority: Priority
        let continuation: CheckedContinuation<Void, Error>
    }
    private var occupied = false
    private var waiters: [Waiter] = []
    var waitingCount: Int { waiters.count }

    func acquire(_ priority: Priority) async throws {
        let id = UUID()
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else if !occupied { occupied = true; continuation.resume() }
                else { waiters.append(Waiter(id: id, priority: priority, continuation: continuation)) }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func release() {
        guard !waiters.isEmpty else { occupied = false; return }
        let index = waiters.firstIndex { $0.priority == .translation } ?? 0
        let next = waiters.remove(at: index)
        next.continuation.resume()
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

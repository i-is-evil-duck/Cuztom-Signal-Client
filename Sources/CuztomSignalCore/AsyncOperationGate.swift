import Foundation

/// Reentrancy-safe async mutex used for short, service-wide lifecycle
/// transitions. An actor alone is not sufficient here: an actor method that
/// awaits would allow a second lifecycle operation to interleave.
actor AsyncOperationGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var held = false
    private var waiters: [Waiter] = []
    private var cancelledWaiterIDs: Set<UUID> = []

    func run<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let waiterID = try await acquire()
        defer {
            if let waiterID { cancelledWaiterIDs.remove(waiterID) }
            release()
        }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire() async throws -> UUID? {
        if !held {
            held = true
            return nil
        }

        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled || cancelledWaiterIDs.remove(id) != nil {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
        return id
    }

    private func cancelWaiter(_ id: UUID) {
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            let waiter = waiters.remove(at: index)
            waiter.continuation.resume(throwing: CancellationError())
        } else {
            // The cancellation handler can run just before the continuation
            // is appended. Retain the ID until that append observes it.
            cancelledWaiterIDs.insert(id)
        }
    }

    private func release() {
        if waiters.isEmpty {
            held = false
        } else {
            let waiter = waiters.removeFirst()
            waiter.continuation.resume(returning: ())
        }
    }
}

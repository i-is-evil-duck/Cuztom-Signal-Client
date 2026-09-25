import Foundation

private final class NativeCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

/// Process-wide serial executor for native Signal/RingRTC calls.
///
/// The native worker, `core_last_error`, and the RingRTC actor are process
/// global. Keeping every FFI invocation on one queue gives logout/wipe a clear
/// ordering point: a command already in flight finishes before teardown runs,
/// while a command queued after session invalidation is rejected before it can
/// touch the native worker.
final class SerialNativeExecutor: @unchecked Sendable {
    static let shared = SerialNativeExecutor(label: "com.cuztom-signal.native")

    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt8>()

    init(label: String) {
        queue = DispatchQueue(label: label, qos: .userInitiated)
        queue.setSpecific(key: queueKey, value: 1)
    }

    /// Synchronous compatibility bridge for startup/loader code. Calls made
    /// from the executor itself are re-entrant; calls from other threads wait
    /// in the same serial order as async native commands.
    func runSync<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) throws -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return try operation()
        }
        return try queue.sync { try operation() }
    }

    func run<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T,
        onEnqueue: (@Sendable () -> Void)? = nil
    ) async throws -> T {
        let cancellation = NativeCancellationFlag()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                onEnqueue?()
                queue.async {
                    if cancellation.isCancelled {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    do {
                        // Once a non-cancellable native call starts, deliver
                        // its result even if the caller cancels meanwhile.
                        // Reporting failure after a send/wipe may have taken
                        // effect would encourage unsafe duplicate retries.
                        continuation.resume(returning: try operation())
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}

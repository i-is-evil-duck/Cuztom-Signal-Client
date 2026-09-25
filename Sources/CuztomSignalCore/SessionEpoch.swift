import Foundation

/// Lock-backed monotonic session token used to invalidate work from an old
/// native account. It is intentionally independent of the larger
/// RustCoreService actorization work so the event pump can fail closed now.
final class SessionEpoch: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    func invalidate() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        value &+= 1
        return value
    }

    func current() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func isCurrent(_ candidate: UInt64) -> Bool {
        current() == candidate
    }
}

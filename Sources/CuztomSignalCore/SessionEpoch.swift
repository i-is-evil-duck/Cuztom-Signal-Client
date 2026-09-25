import Foundation

/// Opaque value captured by work that belongs to one native account session.
/// It is intentionally not reconstructible from the current epoch, so a task
/// cannot silently move itself into a replacement account after a wipe.
struct SessionToken: Hashable, Sendable {
    fileprivate let value: UInt64
}

/// Lock-backed lifecycle gate for native-account work.
///
/// `suspend()` is used by authoritative teardown. While suspended, no new
/// operation can capture a token; `beginLinking()` must explicitly resume the
/// service before a replacement account can be provisioned.
final class SessionEpoch: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    private var suspended = false
    private var poisoned = false

    func capture() throws -> SessionToken {
        lock.lock()
        defer { lock.unlock() }
        guard !suspended else { throw SignalError.sessionInvalidated }
        return SessionToken(value: value)
    }

    /// Starts a new linked/live session, invalidating all older work.
    @discardableResult
    func rotate() throws -> SessionToken {
        lock.lock()
        defer { lock.unlock() }
        guard !suspended else { throw SignalError.sessionInvalidated }
        value &+= 1
        return SessionToken(value: value)
    }

    /// Invalidates old work while allowing a subsequent relink on this service.
    @discardableResult
    func invalidate() -> SessionToken {
        lock.lock()
        defer { lock.unlock() }
        value &+= 1
        return SessionToken(value: value)
    }

    /// Retires the service until an explicit resume. This closes the window in
    /// which an old task could start after a wipe and capture the next token.
    @discardableResult
    func suspend() -> SessionToken {
        lock.lock()
        defer { lock.unlock() }
        suspended = true
        value &+= 1
        return SessionToken(value: value)
    }

    /// Reopens a suspended service, or returns the current token when the
    /// service is already active. This keeps a mere resume probe from
    /// invalidating a live event pump.
    @discardableResult
    func resumeIfNeeded() throws -> SessionToken {
        lock.lock()
        defer { lock.unlock() }
        guard !poisoned else { throw SignalError.sessionInvalidated }
        if suspended {
            suspended = false
            value &+= 1
        }
        return SessionToken(value: value)
    }

    /// Explicitly reopens the service for a fresh account after a full wipe.
    @discardableResult
    func resume() throws -> SessionToken {
        lock.lock()
        defer { lock.unlock() }
        guard !poisoned else { throw SignalError.sessionInvalidated }
        suspended = false
        value &+= 1
        return SessionToken(value: value)
    }

    /// Marks teardown as unrecoverable. A failed native wipe/logout must not
    /// be followed by a relink on the same service instance.
    func poison() {
        lock.lock()
        poisoned = true
        suspended = true
        value &+= 1
        lock.unlock()
    }

    func require(_ token: SessionToken) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !suspended, token.value == value else {
            throw SignalError.sessionInvalidated
        }
    }

    /// Runs a short, synchronous commit only while the token is current. User
    /// callbacks must never be invoked while this lock is held.
    func withCurrent<T>(_ token: SessionToken, _ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard !suspended, token.value == value else {
            throw SignalError.sessionInvalidated
        }
        return try body()
    }

    func isCurrent(_ token: SessionToken) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !suspended && token.value == value
    }

    var isSuspended: Bool {
        lock.lock()
        defer { lock.unlock() }
        return suspended
    }

    var isPoisoned: Bool {
        lock.lock()
        defer { lock.unlock() }
        return poisoned
    }

    /// Compatibility/debug helper; callers should normally retain a token.
    func current() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

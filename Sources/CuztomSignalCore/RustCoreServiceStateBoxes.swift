import Foundation

/// Lock-backed storage for the dlopen handle and resolved path. The loader
/// runs on the serial native queue, but diagnostics and startup read these
/// values from other isolation domains.
final class NativeLibraryBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedHandle: UnsafeMutableRawPointer?
    private var storedPath: String?

    var handle: UnsafeMutableRawPointer? {
        lock.lock()
        defer { lock.unlock() }
        return storedHandle
    }

    var path: String? {
        lock.lock()
        defer { lock.unlock() }
        return storedPath
    }

    var isLoaded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedHandle != nil
    }

    func install(handle: UnsafeMutableRawPointer, path: String) {
        lock.lock()
        storedHandle = handle
        storedPath = path
        lock.unlock()
    }
}

/// Lock-backed native initialization/linked state. The recursive lock allows
/// the initialization helper to read and update the fields while holding the
/// same serialization boundary.
final class NativeSessionStateBox: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var storedInitialized = false
    private var storedLinked = false

    var initialized: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedInitialized
    }

    var linked: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedLinked
    }

    func setInitialized(_ value: Bool) {
        lock.lock()
        storedInitialized = value
        lock.unlock()
    }

    func setLinked(_ value: Bool) {
        lock.lock()
        storedLinked = value
        lock.unlock()
    }

    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

/// Lock-backed owner for the service event-pump task. This is intentionally
/// separate from actor/cache state so `deinit` and teardown can cancel it
/// without touching isolated mutable state.
final class PumpTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    func take() -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        let value = task
        task = nil
        return value
    }

    func set(_ value: Task<Void, Never>) {
        lock.lock()
        task = value
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let value = task
        task = nil
        lock.unlock()
        value?.cancel()
    }
}

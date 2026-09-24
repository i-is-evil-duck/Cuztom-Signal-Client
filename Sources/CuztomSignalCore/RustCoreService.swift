import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// M1: `SignalService` backed by `rust-core/` (`presage` Manager) over C FFI.
///
/// Expected C ABI (see `rust-core/src/lib.rs`):
///   `core_cmd_init(db_path) -> i32`   1 linked, 0 fresh, -1 error
///   `core_cmd_begin_link(name) -> *mut c_char` (free with `core_free_string`)
///   `core_cmd_poll_link() -> i32`     1 linked, 0 pending, -1 failed
///   `core_cmd_is_linked() -> i32`     1 / 0
///   `core_last_error() -> *const c_char`
///   `core_free_string(*mut c_char)`
///
/// The library is loaded lazily with `dlopen` so the Swift package still
/// builds/tests on machines without Rust. Conversation/message sync lands in
/// M1b; until then an established link reports an empty roster.
public final class RustCoreService: SignalService, @unchecked Sendable {
    private let stateContinuation: AsyncStream<ConnectionState>.Continuation
    public let connectionState: AsyncStream<ConnectionState>

    private let incomingContinuation: AsyncStream<ChatMessage>.Continuation
    private let incoming: AsyncStream<ChatMessage>

    private var libraryHandle: UnsafeMutableRawPointer?
    public private(set) var libraryPath: String?
    private let explicitPath: String?
    private let dbPath: String
    private var didInit = false
    private var linked = false

    public init(libraryPath: String? = nil, dbPath: String? = nil) {
        self.libraryPath = libraryPath
        self.explicitPath = libraryPath
        self.dbPath = dbPath ?? Self.defaultDBPath()
        var sc: AsyncStream<ConnectionState>.Continuation!
        self.connectionState = AsyncStream { sc = $0 }
        self.stateContinuation = sc
        var ic: AsyncStream<ChatMessage>.Continuation!
        self.incoming = AsyncStream { ic = $0 }
        self.incomingContinuation = ic
        if let path = libraryPath {
            libraryHandle = Self.openLibrary(at: path)
            if libraryHandle != nil { self.libraryPath = path }
        }
    }

    deinit {
        if let handle = libraryHandle {
            #if canImport(Darwin)
            dlclose(handle)
            #endif
        }
    }

    public static func defaultDBPath() -> String {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))?.path ?? NSTemporaryDirectory()
        return (base as NSString).appendingPathComponent("CuztomSignal/signal.db")
    }

    public static func defaultSearchPaths() -> [String] {
        var paths: [String] = []
        if let exeDir = Bundle.main.executableURL?.deletingLastPathComponent().path {
            paths.append((exeDir as NSString).appendingPathComponent("libcuztom_signal_core.dylib"))
        }
        let fm = FileManager.default
        if let appSupport = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false) {
            paths.append(appSupport.appendingPathComponent("CuztomSignal/libcuztom_signal_core.dylib").path)
        }
        // Dev checkouts: release first, then debug.
        let cwd = fm.currentDirectoryPath
        paths.append((cwd as NSString).appendingPathComponent("rust-core/target/release/libcuztom_signal_core.dylib"))
        paths.append((cwd as NSString).appendingPathComponent("rust-core/target/debug/libcuztom_signal_core.dylib"))
        return paths
    }

    public var isLibraryLoaded: Bool { libraryHandle != nil }

    @discardableResult
    public func loadLibrary() -> Bool {
        if libraryHandle != nil { return true }
        // An explicit path is strict: a missing file means "not available",
        // never silently fall back to a different build (test determinism).
        if explicitPath != nil { return false }
        for path in Self.defaultSearchPaths() {
            if let handle = Self.openLibrary(at: path) {
                libraryHandle = handle
                libraryPath = path
                return true
            }
        }
        return false
    }

    public func beginLinking(deviceName: String) async throws -> LinkQR {
        let sym = try await initCore()
        stateContinuation.yield(.linking)
        let url: String = try callString(sym.beginLink, deviceName, what: "begin_link")
        linked = false
        return LinkQR(payload: url)
    }

    public func waitForLink() async throws {
        let sym = try await initCore()
        // Phone scan can take minutes; poll the worker until it resolves.
        let deadline = Date().addingTimeInterval(300)
        while Date() < deadline {
            let rc = sym.pollLink()
            if rc == 1 {
                linked = true
                stateContinuation.yield(.connected)
                return
            }
            if rc < 0 {
                throw SignalError.network("link failed: \(lastError(sym))")
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw SignalError.network("link timed out waiting for phone scan")
    }

    public func fetchConversations() async throws -> [Conversation] {
        guard linked || isLinkedNow() else { throw SignalError.notLinked }
        // M1b implements roster sync; empty (not throw) keeps link flow alive.
        return []
    }

    public func fetchMessages(conversationId: String, limit: Int) async throws -> [ChatMessage] {
        guard linked || isLinkedNow() else { throw SignalError.notLinked }
        return []
    }

    public func sendText(_ body: String, to conversationId: String) async throws -> ChatMessage {
        guard linked || isLinkedNow() else { throw SignalError.notLinked }
        throw SignalError.unsupported("send path lands in M1b (receive loop + send)")
    }

    public func incomingMessages() -> AsyncStream<ChatMessage> {
        incoming
    }

    /// Offline-safe: opens (or creates) the store and reports whether a
    /// linked session exists. No network traffic. Used by setup/tests.
    public func isLinkedAccount() async throws -> Bool {
        let sym = try await initCore()
        return sym.isLinked() == 1
    }

    // MARK: - private FFI

    private struct Symbols {
        let initCore: @convention(c) (UnsafePointer<CChar>) -> Int32
        let beginLink: @convention(c) (UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
        let pollLink: @convention(c) () -> Int32
        let isLinked: @convention(c) () -> Int32
        let lastError: @convention(c) () -> UnsafePointer<CChar>?
        let freeString: @convention(c) (UnsafeMutablePointer<CChar>?) -> Void
    }

    private func initCore() async throws -> Symbols {
        guard loadLibrary(), let handle = libraryHandle else {
            throw SignalError.unsupported("rust core not bundled — build it: cd rust-core && cargo build --release (see rust-core/README)")
        }
        guard let sym = Self.resolve(in: handle) else {
            throw SignalError.crypto("rust core dylib missing expected symbols (rebuild rust-core/)")
        }
        if !didInit {
            let rc: Int32 = dbPath.withCString { sym.initCore($0) }
            if rc < 0 { throw SignalError.storage("core init failed: \(lastError(sym))") }
            didInit = true
            linked = (rc == 1)
        }
        return sym
    }

    private func isLinkedNow() -> Bool {
        guard let handle = libraryHandle, let sym = Self.resolve(in: handle) else { return false }
        return sym.isLinked() == 1
    }

    private func lastError(_ sym: Symbols) -> String {
        guard let ptr = sym.lastError() else { return "unknown" }
        return String(cString: ptr)
    }

    private func callString(_ fn: @convention(c) (UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?, _ arg: String, what: String) throws -> String {
        var result: UnsafeMutablePointer<CChar>? = nil
        arg.withCString { result = fn($0) }
        guard let ptr = result else {
            guard let handle = libraryHandle, let sym = Self.resolve(in: handle) else {
                throw SignalError.crypto("\(what): null without loaded library")
            }
            throw SignalError.network("\(what) failed: \(lastError(sym))")
        }
        // Copy out, then free the Rust allocation via the library (not free()).
        let value = String(cString: ptr)
        if let handle = libraryHandle, let sym = Self.resolve(in: handle) {
            sym.freeString(ptr)
        }
        return value
    }

    private static func resolve(in handle: UnsafeMutableRawPointer) -> Symbols? {
        #if canImport(Darwin)
        guard let i = dlsym(handle, "core_cmd_init"),
              let b = dlsym(handle, "core_cmd_begin_link"),
              let p = dlsym(handle, "core_cmd_poll_link"),
              let l = dlsym(handle, "core_cmd_is_linked"),
              let e = dlsym(handle, "core_last_error"),
              let f = dlsym(handle, "core_free_string") else { return nil }
        return Symbols(
            initCore: unsafeBitCast(i, to: (@convention(c) (UnsafePointer<CChar>) -> Int32).self),
            beginLink: unsafeBitCast(b, to: (@convention(c) (UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?).self),
            pollLink: unsafeBitCast(p, to: (@convention(c) () -> Int32).self),
            isLinked: unsafeBitCast(l, to: (@convention(c) () -> Int32).self),
            lastError: unsafeBitCast(e, to: (@convention(c) () -> UnsafePointer<CChar>?).self),
            freeString: unsafeBitCast(f, to: (@convention(c) (UnsafeMutablePointer<CChar>?) -> Void).self)
        )
        #else
        return nil
        #endif
    }

    private static func openLibrary(at path: String) -> UnsafeMutableRawPointer? {
        #if canImport(Darwin)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return dlopen(path, RTLD_NOW | RTLD_LOCAL)
        #else
        return nil
        #endif
    }
}

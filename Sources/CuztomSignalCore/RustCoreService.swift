import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// M1 seam: `SignalService` backed by `rust-core/` (`presage` Manager) over C FFI.
///
/// Expected C ABI (see `rust-core/src/lib.rs`):
///   `link_device_qr(*const c_char) -> *mut c_char`
///   `core_free_string(*mut c_char)`
///
/// The library is loaded lazily with `dlopen` so the Swift package still
/// builds/tests on machines without Rust. Until M1 wires the real Manager,
/// every operation throws `SignalError.unsupported` with an actionable hint.
public final class RustCoreService: SignalService, @unchecked Sendable {
    private let stateContinuation: AsyncStream<ConnectionState>.Continuation
    public let connectionState: AsyncStream<ConnectionState>

    private let incomingContinuation: AsyncStream<ChatMessage>.Continuation
    private let incoming: AsyncStream<ChatMessage>

    private var libraryHandle: UnsafeMutableRawPointer?
    public private(set) var libraryPath: String?

    public init(libraryPath: String? = nil) {
        self.libraryPath = libraryPath
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

    public static func defaultSearchPaths() -> [String] {
        let fm = FileManager.default
        let appSupport = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false))?.path ?? ""
        return [
            Bundle.main.path(forResource: "cuztom_signal_core", ofType: "dylib"),
            appSupport + "/CuztomSignal/libcuztom_signal_core.dylib",
            "./rust-core/target/release/libcuztom_signal_core.dylib",
        ].compactMap { $0 }
    }

    public var isLibraryLoaded: Bool { libraryHandle != nil }

    @discardableResult
    public func loadLibrary() -> Bool {
        if libraryHandle != nil { return true }
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
        guard loadLibrary(), libraryHandle != nil else {
            throw SignalError.unsupported("rust core not bundled — build it: cd rust-core && cargo build (see rust-core/README)")
        }
        // M1: resolve `link_device_qr`, pass deviceName, marshal the
        // returned QR URI, then `core_free_string`. Until the Manager
        // exists server-side, fail loudly instead of faking a QR.
        throw SignalError.unsupported("link_device_qr not yet implemented in rust-core (M1 in progress)")
    }

    public func waitForLink() async throws {
        throw SignalError.unsupported("link polling lands with the presage Manager (M1 in progress)")
    }

    public func fetchConversations() async throws -> [Conversation] {
        throw SignalError.unsupported("conversation sync lands with the presage Manager (M1 in progress)")
    }

    public func fetchMessages(conversationId: String, limit: Int) async throws -> [ChatMessage] {
        throw SignalError.unsupported("message sync lands with the presage Manager (M1 in progress)")
    }

    public func sendText(_ body: String, to conversationId: String) async throws -> ChatMessage {
        throw SignalError.unsupported("send path lands with the presage Manager (M1 in progress)")
    }

    public func incomingMessages() -> AsyncStream<ChatMessage> {
        incoming
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

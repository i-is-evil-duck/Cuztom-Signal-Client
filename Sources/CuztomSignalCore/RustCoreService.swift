import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// Decoded roster snapshot from `core_cmd_roster` (see rust-core/src/sync.rs).
public struct RosterPayload: Decodable, Sendable {
    public struct SelfInfo: Decodable, Sendable {
        public var aci: String
        public var number: String
    }
    public struct Contact: Decodable, Sendable {
        public var id: String
        public var name: String
        public var phone: String
    }
    public struct Group: Decodable, Sendable {
        public var id: String
        public var title: String
    }
    public struct Message: Decodable, Sendable {
        public var key: String
        public var thread: String
        public var sender: String
        public var senderName: String
        public var body: String
        public var ts: Int64
        public var outgoing: Bool

        private enum CodingKeys: String, CodingKey {
            case key, thread, sender, body, ts, outgoing
            case senderName = "sender_name"
        }
    }
    public var thisDevice: SelfInfo
    public var contacts: [Contact]
    public var groups: [Group]
    public var messages: [Message]

    private enum CodingKeys: String, CodingKey {
        case contacts, groups, messages
        case thisDevice = "self"
    }
}

struct LiveEvent: Decodable {
    var type: String
    var message: RosterPayload.Message?
}

/// M1: `SignalService` backed by `rust-core/` (`presage` Manager) over C FFI.
///
/// Expected C ABI (see `rust-core/src/lib.rs`):
///   `core_cmd_init(db_path) -> i32`   1 linked, 0 fresh, -1 error
///   `core_cmd_begin_link(name) -> *mut c_char` (free with `core_free_string`)
///   `core_cmd_poll_link() -> i32`     1 linked, 0 pending, -1 failed
///   `core_cmd_is_linked() -> i32`     1 / 0
///   `core_cmd_roster() -> *mut c_char` (JSON snapshot, free with `core_free_string`)
///   `core_cmd_send(thread, body) -> i64` (sent ts, -1 on error)
///   `core_cmd_start_sync() -> i32` / `core_cmd_poll_event() -> *mut c_char`
///   `core_last_error() -> *const c_char`
///   `core_free_string(*mut c_char)`
///
/// The library is loaded lazily with `dlopen` so the Swift package still
/// builds/tests on machines without Rust.
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
    /// Last roster snapshot, keyed by stable wire key (dedupe across refresh).
    private var messageCache: [String: RosterPayload.Message] = [:]
    private var uuidCache: [String: UUID] = [:]
    private var pumpTask: Task<Void, Never>?

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
        pumpTask?.cancel()
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
        // Resume path: a session from a previous launch is already live —
        // the caller treats `alreadyLinked` as "skip the QR, just sync".
        if sym.isLinked() == 1 {
            linked = true
            throw SignalError.alreadyLinked
        }
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
        let payload = try JSONDecoder().decode(RosterPayload.self, from: try await rosterData())
        return applyRoster(payload)
    }

    public func fetchMessages(conversationId: String, limit: Int) async throws -> [ChatMessage] {
        guard linked || isLinkedNow() else { throw SignalError.notLinked }
        let cached = messageCache.values.filter { $0.thread == conversationId }
            .sorted { $0.ts < $1.ts }
        return Array(cached.suffix(limit)).map { chatMessage($0) }
    }

    public func sendText(_ body: String, to conversationId: String) async throws -> ChatMessage {
        guard linked || isLinkedNow() else { throw SignalError.notLinked }
        let sym = try await initCore()
        var ts: Int64 = -1
        conversationId.withCString { t in
            body.withCString { b in
                ts = sym.send(t, b)
            }
        }
        guard ts >= 0 else { throw SignalError.network("send failed: \(lastError(sym))") }
        let msg = RosterPayload.Message(
            key: "\(conversationId)/\(ts)/self",
            thread: conversationId, sender: "self", senderName: "You",
            body: body, ts: ts, outgoing: true
        )
        return chatMessage(msg)
    }

    public func incomingMessages() -> AsyncStream<ChatMessage> {
        incoming
    }

    /// After link: ask the phone for contact sync, start the receive loop,
    /// and pump events into `incomingMessages()`. Throws only if the loop
    /// itself won't start; a failed contact-sync request is non-fatal.
    public func startLiveSync() async throws {
        let sym = try await initCore()
        if sym.requestContacts() != 0 {
            // Non-fatal: contacts may already be synced from a previous run.
            stateContinuation.yield(.syncing)
        }
        guard sym.startSync() == 0 else {
            throw SignalError.network("start sync failed: \(lastError(sym))")
        }
        pumpTask?.cancel()
        pumpTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.drainEvents()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    /// Offline-safe: opens (or creates) the store and reports whether a
    /// linked session exists. No network traffic. Used by setup/tests.
    public func isLinkedAccount() async throws -> Bool {
        let sym = try await initCore()
        return sym.isLinked() == 1
    }

    /// Offline identity (aci + number) from the local store. No network.
    public struct WhoAmI: Decodable, Sendable {
        public var aci: String
        public var number: String
    }

    public func whoami() async throws -> WhoAmI {
        let sym = try await initCore()
        guard let ptr = sym.whoami() else {
            throw SignalError.network("whoami failed: \(lastError(sym))")
        }
        defer { sym.freeString(ptr) }
        guard let data = String(cString: ptr).data(using: .utf8) else {
            throw SignalError.storage("whoami is not UTF-8")
        }
        return try JSONDecoder().decode(WhoAmI.self, from: data)
    }

    /// Ask the phone to (re-)send the contact/group sync.
    public func requestContactSync() async throws {
        let sym = try await initCore()
        guard sym.requestContacts() == 0 else {
            throw SignalError.network("request sync failed: \(lastError(sym))")
        }
    }

    /// Wipe the session (keys + registration). Next `beginLinking` shows a
    /// fresh QR. Local history cache is dropped with it.
    public func logout() async throws {
        let sym = try await initCore()
        guard sym.logout() == 0 else {
            throw SignalError.network("logout failed: \(lastError(sym))")
        }
        pumpTask?.cancel()
        pumpTask = nil
        linked = false
        messageCache = [:]
        uuidCache = [:]
        lastRosterSummary = "never"
    }

    // MARK: - private FFI

    private struct Symbols {
        let initCore: @convention(c) (UnsafePointer<CChar>) -> Int32
        let beginLink: @convention(c) (UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
        let pollLink: @convention(c) () -> Int32
        let isLinked: @convention(c) () -> Int32
        let roster: @convention(c) () -> UnsafeMutablePointer<CChar>?
        let send: @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int64
        let requestContacts: @convention(c) () -> Int32
        let startSync: @convention(c) () -> Int32
        let pollEvent: @convention(c) () -> UnsafeMutablePointer<CChar>?
        let whoami: @convention(c) () -> UnsafeMutablePointer<CChar>?
        let logout: @convention(c) () -> Int32
        let lastError: @convention(c) () -> UnsafePointer<CChar>?
        let freeString: @convention(c) (UnsafeMutablePointer<CChar>?) -> Void
    }

    /// Non-message sync traffic ("queue_empty", "contacts_synced",
    /// "sync_error:…"). Fires on an internal task — hop threads as needed.
    public var onSyncEvent: ((String) -> Void)?

    /// "12 contacts, 3 groups, 45 msgs @ 22:01" or "never".
    public private(set) var lastRosterSummary = "never"

    /// Fetch + cache the roster snapshot; returns decoded conversations.
    @discardableResult
    public func applyRoster(_ payload: RosterPayload) -> [Conversation] {
        for m in payload.messages {
            messageCache[m.key] = m
        }
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        lastRosterSummary = "\(payload.contacts.count) contacts, \(payload.groups.count) groups, \(payload.messages.count) msgs @ \(fmt.string(from: Date()))"
        var byThread: [String: [RosterPayload.Message]] = [:]
        for m in messageCache.values {
            byThread[m.thread, default: []].append(m)
        }
        var convs: [Conversation] = []
        for c in payload.contacts {
            let id = "contact:\(c.id)"
            let title = c.name.isEmpty ? (c.phone.isEmpty ? String(c.id.prefix(8)) : c.phone) : c.name
            let recent = (byThread[id] ?? []).sorted { $0.ts < $1.ts }
            convs.append(Conversation(
                id: id,
                title: title,
                peer: SignalAddress(uuidString: c.id, phone: c.phone.isEmpty ? nil : c.phone),
                lastMessagePreview: recent.last.map { String($0.body.prefix(120)) },
                lastActiveAt: recent.last.map { Date(timeIntervalSince1970: Double($0.ts) / 1000) } ?? Date.distantPast,
                unreadCount: 0
            ))
        }
        for g in payload.groups {
            let id = "group:\(g.id)"
            let recent = (byThread[id] ?? []).sorted { $0.ts < $1.ts }
            convs.append(Conversation(
                id: id,
                title: g.title.isEmpty ? "Unnamed group" : g.title,
                peer: SignalAddress(groupId: "group.\(g.id)"),
                lastMessagePreview: recent.last.map { String($0.body.prefix(120)) },
                lastActiveAt: recent.last.map { Date(timeIntervalSince1970: Double($0.ts) / 1000) } ?? Date.distantPast,
                unreadCount: 0
            ))
        }
        return convs.sorted { $0.lastActiveAt > $1.lastActiveAt }
    }

    public func chatMessage(_ m: RosterPayload.Message) -> ChatMessage {
        let id: UUID
        if let existing = uuidCache[m.key] {
            id = existing
        } else {
            let fresh = UUID()
            uuidCache[m.key] = fresh
            id = fresh
        }
        let isGroup = m.thread.hasPrefix("group:")
        return ChatMessage(
            id: id,
            conversationId: m.thread,
            author: SignalAddress(
                uuidString: m.outgoing ? nil : m.sender,
                groupId: isGroup ? m.thread : nil
            ),
            body: m.body.isEmpty ? "[attachment]" : m.body,
            direction: m.outgoing ? .outgoing : .incoming,
            status: m.outgoing ? .sent : .delivered,
            sentAt: Date(timeIntervalSince1970: Double(m.ts) / 1000)
        )
    }

    private func rosterData() async throws -> Data {
        let sym = try await initCore()
        guard let ptr = sym.roster() else {
            throw SignalError.network("roster failed: \(lastError(sym))")
        }
        defer { sym.freeString(ptr) }
        guard let data = String(cString: ptr).data(using: .utf8) else {
            throw SignalError.storage("roster is not UTF-8")
        }
        return data
    }

    private func drainEvents() {
        guard let handle = libraryHandle, let sym = Self.resolve(in: handle) else { return }
        while let ptr = sym.pollEvent() {
            defer { sym.freeString(ptr) }
            let text = String(cString: ptr)
            guard let data = text.data(using: .utf8),
                  let event = try? JSONDecoder().decode(LiveEvent.self, from: data) else { continue }
            if event.type == "message", let msg = event.message {
                messageCache[msg.key] = msg
                incomingContinuation.yield(chatMessage(msg))
            } else {
                onSyncEvent?(event.type)
            }
        }
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
              let r = dlsym(handle, "core_cmd_roster"),
              let s = dlsym(handle, "core_cmd_send"),
              let q = dlsym(handle, "core_cmd_request_contacts"),
              let y = dlsym(handle, "core_cmd_start_sync"),
              let v = dlsym(handle, "core_cmd_poll_event"),
              let w = dlsym(handle, "core_cmd_whoami"),
              let o = dlsym(handle, "core_cmd_logout"),
              let e = dlsym(handle, "core_last_error"),
              let f = dlsym(handle, "core_free_string") else { return nil }
        return Symbols(
            initCore: unsafeBitCast(i, to: (@convention(c) (UnsafePointer<CChar>) -> Int32).self),
            beginLink: unsafeBitCast(b, to: (@convention(c) (UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?).self),
            pollLink: unsafeBitCast(p, to: (@convention(c) () -> Int32).self),
            isLinked: unsafeBitCast(l, to: (@convention(c) () -> Int32).self),
            roster: unsafeBitCast(r, to: (@convention(c) () -> UnsafeMutablePointer<CChar>?).self),
            send: unsafeBitCast(s, to: (@convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int64).self),
            requestContacts: unsafeBitCast(q, to: (@convention(c) () -> Int32).self),
            startSync: unsafeBitCast(y, to: (@convention(c) () -> Int32).self),
            pollEvent: unsafeBitCast(v, to: (@convention(c) () -> UnsafeMutablePointer<CChar>?).self),
            whoami: unsafeBitCast(w, to: (@convention(c) () -> UnsafeMutablePointer<CChar>?).self),
            logout: unsafeBitCast(o, to: (@convention(c) () -> Int32).self),
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

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
        public var sts: Int64
        public var outgoing: Bool
        public var attachments: [WireAttachment]

        private enum CodingKeys: String, CodingKey {
            case key, thread, sender, body, ts, sts, outgoing, attachments
            case senderName = "sender_name"
        }

        public init(
            key: String, thread: String, sender: String, senderName: String,
            body: String, ts: Int64, outgoing: Bool, attachments: [WireAttachment] = []
        ) {
            self.key = key
            self.thread = thread
            self.sender = sender
            self.senderName = senderName
            self.body = body
            self.ts = ts
            self.sts = ts
            self.outgoing = outgoing
            self.attachments = attachments
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            key = try c.decode(String.self, forKey: .key)
            thread = try c.decode(String.self, forKey: .thread)
            sender = try c.decode(String.self, forKey: .sender)
            senderName = try c.decode(String.self, forKey: .senderName)
            body = try c.decode(String.self, forKey: .body)
            ts = try c.decode(Int64.self, forKey: .ts)
            // Older snapshots predate sts; fall back to display ts.
            sts = try c.decodeIfPresent(Int64.self, forKey: .sts) ?? ts
            outgoing = try c.decode(Bool.self, forKey: .outgoing)
            attachments = try c.decodeIfPresent([WireAttachment].self, forKey: .attachments) ?? []
        }
    }

    public struct WireAttachment: Decodable, Sendable {
        public var name: String
        public var mime: String
        public var size: Int
        public var path: String?
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
    // reaction
    var thread: String?
    var targetSts: Int64?
    var emoji: String?
    var remove: Bool?
    var sender: String?
    var senderName: String?
    // receipt
    var kind: String?
    var timestamps: [Int64]?

    private enum CodingKeys: String, CodingKey {
        case type, message, thread, emoji, remove, sender, kind, timestamps
        case targetSts = "target_sts"
        case senderName = "sender_name"
    }
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
    /// Own ACI (resolved after linking via whoami) for identifying our own messages.
    public var selfAci: String?
    /// Last roster snapshot, keyed by stable wire key (dedupe across refresh).
    private var messageCache: [String: RosterPayload.Message] = [:]
    private var uuidCache: [String: UUID] = [:]
    private var pumpTask: Task<Void, Never>?
    /// Wire key -> local file path, persisted across launches so roster
    /// re-seeds don't re-download (or re-prompt) every restart.
    private var pathCache: [String: String] = [:]

    private var pathCacheURL: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))?.path ?? NSTemporaryDirectory()
        return URL(fileURLWithPath: (base as NSString).appendingPathComponent("CuztomSignal/attachment_paths.json"))
    }

    private func loadPathCache() {
        guard let data = try? Data(contentsOf: pathCacheURL),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        // Prune entries whose files vanished (cache eviction, reinstalls).
        pathCache = map.filter { FileManager.default.fileExists(atPath: $0.value) }
    }

    private func savePathCache() {
        guard let data = try? JSONEncoder().encode(pathCache) else { return }
        try? data.write(to: pathCacheURL, options: .atomic)
    }

    private func rememberPath(key: String, path: String) {
        pathCache[key] = path
        savePathCache()
    }

    /// Local override for on-demand downloads, keyed "thread/ts".
    /// Consulted (and persisted) by `chatMessage`.
    private var localPaths: [String: String] = [:]

    public func bindLocalPath(thread: String, ts: Int64, path: String) {
        localPaths["\(thread)/\(ts)"] = path
    }

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
        loadPathCache()
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
        // Merge the seed roster with older pages until `limit` is satisfied.
        // `sts` (store clock) is the ONLY correct paging basis — the SQLite
        // range runs over the client timestamp, not the server one.
        // History only goes back to link time: Signal never syncs older
        // messages to a new linked device (protocol limitation, not a bug).
        var cached = threadCache(conversationId)
        if cached.count < limit {
            let oldest = cached.map(\.sts).min() ?? Int64.max
            let before: UInt64 = oldest <= 0 ? 0 : UInt64(bitPattern: oldest)
            do {
                let page = try await threadPage(conversationId, limit: limit, before: before)
                Log.info("thread page \(conversationId): \(page.count) rows before \(before)")
                for m in page { messageCache[m.key] = m }
                cached = threadCache(conversationId)
            } catch {
                Log.error("thread page failed: \(error)")
                throw error
            }
        }
        return Array(cached.suffix(limit)).map { chatMessage($0) }
    }

    private func threadCache(_ conversationId: String) -> [RosterPayload.Message] {
        messageCache.values.filter { $0.thread == conversationId }.sorted { $0.ts < $1.ts }
    }

    private struct ThreadPage: Decodable {
        var messages: [RosterPayload.Message]
    }

    private func threadPage(_ thread: String, limit: Int, before: UInt64) async throws -> [RosterPayload.Message] {
        let sym = try await initCore()
        var ptr: UnsafeMutablePointer<CChar>? = nil
        thread.withCString { t in
            ptr = sym.threadPage(t, UInt64(limit), before)
        }
        guard let ptr else { throw SignalError.network("thread page failed: \(lastError(sym))") }
        defer { sym.freeString(ptr) }
        guard let data = String(cString: ptr).data(using: .utf8) else {
            throw SignalError.storage("thread page is not UTF-8")
        }
        return try JSONDecoder().decode(ThreadPage.self, from: data).messages
    }

    /// On-demand attachment download for roster-seeded (metadata-only) rows.
    /// `ts` is the store-clock timestamp (see `ChatMessage.storeTs`).
    public func fetchAttachment(thread: String, ts: Int64, index: Int) async throws -> URL {
        let sym = try await initCore()
        var ptr: UnsafeMutablePointer<CChar>? = nil
        thread.withCString { t in
            ptr = sym.fetchAttachment(t, UInt64(bitPattern: ts), UInt64(index))
        }
        guard let ptr else {
            throw SignalError.network("attachment fetch failed: \(lastError(sym))")
        }
        defer { sym.freeString(ptr) }
        return URL(fileURLWithPath: String(cString: ptr))
    }

    /// Upload a local file and send it. Returns (sent ts, filename, mime, size).
    public func sendAttachment(thread: String, path: String, caption: String) async throws -> (ts: Int64, name: String, mime: String, size: Int) {
        let sym = try await initCore()
        var ts: Int64 = -1
        thread.withCString { t in
            path.withCString { p in
                caption.withCString { c in
                    ts = sym.sendAttachment(t, p, c)
                }
            }
        }
        guard ts >= 0 else { throw SignalError.network("attachment send failed: \(lastError(sym))") }
        let url = URL(fileURLWithPath: path)
        return (ts, url.lastPathComponent, mimeFor(url: url), fileSize(url: url))
    }

    /// Reply quoting (`qTs` store-clock, `qAuthor` service id, `qBody`).
    public func sendReply(thread: String, body: String, qTs: Int64, qAuthor: String, qBody: String) async throws -> Int64 {
        let sym = try await initCore()
        var ts: Int64 = -1
        thread.withCString { t in
            body.withCString { b in
                qAuthor.withCString { a in
                    qBody.withCString { q in
                        ts = sym.sendReply(t, b, UInt64(bitPattern: qTs), a, q)
                    }
                }
            }
        }
        guard ts >= 0 else { throw SignalError.network("reply failed: \(lastError(sym))") }
        return ts
    }

    /// Delete-for-everyone tombstone. Local removal is separate.
    public func sendDeleteTombstone(thread: String, targetTs: Int64) async throws {
        let sym = try await initCore()
        var ts: Int64 = -1
        thread.withCString { t in
            ts = sym.sendDelete(t, UInt64(bitPattern: targetTs))
        }
        guard ts >= 0 else { throw SignalError.network("delete send failed: \(lastError(sym))") }
    }

    /// Local-only store removal. Returns true when a row existed.
    public func deleteLocal(thread: String, sts: Int64) async throws -> Bool {
        let sym = try await initCore()
        var rc: Int32 = -1
        thread.withCString { t in
            rc = sym.deleteLocal(t, UInt64(bitPattern: sts))
        }
        guard rc >= 0 else { throw SignalError.network("local delete failed: \(lastError(sym))") }
        return rc == 1
    }

    /// Toggle/add `emoji` reaction on the message at `targetSts`.
    public func sendReaction(thread: String, targetSts: Int64, author: String, emoji: String, remove: Bool) async throws {
        let sym = try await initCore()
        var ts: Int64 = -1
        thread.withCString { t in
            author.withCString { a in
                emoji.withCString { e in
                    ts = sym.sendReaction(t, UInt64(bitPattern: targetSts), a, e, remove ? 1 : 0)
                }
            }
        }
        guard ts >= 0 else { throw SignalError.network("reaction failed: \(lastError(sym))") }
    }

    /// Send a read/delivery receipt for the given message timestamps (store clocks).
    /// `kind` is "read" or "delivered".
    public func sendReceipt(thread: String, timestamps: [Int64], kind: String) async throws {
        let sym = try await initCore()
        let tsArray = timestamps.map { UInt64(bitPattern: $0) }
        let rc = thread.withCString { t in
            kind.withCString { k in
                sym.sendReceipt(t, tsArray, UInt64(tsArray.count), k)
            }
        }
        guard rc == 0 else { throw SignalError.network("send receipt failed: \(lastError(sym))") }
    }

    // MARK: - M4: Call Signaling

    /// Send a call offer (SDP) to start a call.
    public func sendCallOffer(callId: String, to: String, mediaType: String, sdp: String) async throws {
        let sym = try await initCore()
        let rc = callId.withCString { c in
            to.withCString { t in
                mediaType.withCString { m in
                    sdp.withCString { s in
                        sym.sendCallOffer(c, t, m, s)
                    }
                }
            }
        }
        guard rc == 0 else { throw SignalError.network("send call offer failed: \(lastError(sym))") }
    }

    /// Send a call answer (SDP) to accept a call.
    public func sendCallAnswer(callId: String, sdp: String) async throws {
        let sym = try await initCore()
        let rc = callId.withCString { c in
            sdp.withCString { s in
                sym.sendCallAnswer(c, s)
            }
        }
        guard rc == 0 else { throw SignalError.network("send call answer failed: \(lastError(sym))") }
    }

    /// Send an ICE candidate during call setup.
    public func sendCallIceCandidate(callId: String, candidate: String, sdpMid: String, sdpMLineIndex: UInt32) async throws {
        let sym = try await initCore()
        let rc = callId.withCString { c in
            candidate.withCString { cand in
                sdpMid.withCString { mid in
                    sym.sendCallIce(c, cand, mid, sdpMLineIndex)
                }
            }
        }
        guard rc == 0 else { throw SignalError.network("send call ice failed: \(lastError(sym))") }
    }

    /// Send a call hangup.
    public func sendCallHangup(callId: String, reason: String) async throws {
        let sym = try await initCore()
        let rc = callId.withCString { c in
            reason.withCString { r in
                sym.sendCallHangup(c, r)
            }
        }
        guard rc == 0 else { throw SignalError.network("send call hangup failed: \(lastError(sym))") }
    }

    /// Profile display name for a contact uuid (nil when unavailable).
    public func profileName(uuid: String) async -> String? {
        guard let sym = try? await initCore() else { return nil }
        var ptr: UnsafeMutablePointer<CChar>? = nil
        uuid.withCString { u in
            ptr = sym.profile(u)
        }
        guard let ptr else { return nil }
        defer { sym.freeString(ptr) }
        let name = String(cString: ptr)
        return name.isEmpty ? nil : name
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
        let threadPage: @convention(c) (UnsafePointer<CChar>, UInt64, UInt64) -> UnsafeMutablePointer<CChar>?
        let fetchAttachment: @convention(c) (UnsafePointer<CChar>, UInt64, UInt64) -> UnsafeMutablePointer<CChar>?
        let sendAttachment: @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int64
        let sendReply: @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>, UInt64, UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int64
        let sendDelete: @convention(c) (UnsafePointer<CChar>, UInt64) -> Int64
        let sendReaction: @convention(c) (UnsafePointer<CChar>, UInt64, UnsafePointer<CChar>, UnsafePointer<CChar>, Int32) -> Int64
        let sendReceipt: @convention(c) (UnsafePointer<CChar>, UnsafePointer<UInt64>, UInt64, UnsafePointer<CChar>) -> Int32
        let sendCallOffer: @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int32
        let sendCallAnswer: @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int32
        let sendCallIce: @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafePointer<CChar>, UInt32) -> Int32
        let sendCallHangup: @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int32
        let deleteLocal: @convention(c) (UnsafePointer<CChar>, UInt64) -> Int32
        let profile: @convention(c) (UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
        let whoami: @convention(c) () -> UnsafeMutablePointer<CChar>?
        let logout: @convention(c) () -> Int32
        let lastError: @convention(c) () -> UnsafePointer<CChar>?
        let freeString: @convention(c) (UnsafeMutablePointer<CChar>?) -> Void
    }

    /// Non-message sync traffic ("queue_empty", "contacts_synced",
    /// "sync_error:…"). Fires on an internal task — hop threads as needed.
    public var onSyncEvent: ((String) -> Void)?

    /// Live reaction: (thread, target store-ts, emoji, remove, sender name).
    public var onReaction: ((String, Int64, String, Bool, String) -> Void)?

    /// Live receipt: (sender name, "read"|"delivered", message timestamps).
    public var onReceipt: ((String, String, [Int64]) -> Void)?

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
        var metas: [AttachmentMeta] = []
        for (index, a) in m.attachments.enumerated() {
            // Newest source wins: live/on-demand override, then persisted
            // cache, then the wire path. Missing files fall back to manual.
            // Cache keys are per-attachment (message key + index).
            let cacheKey = "\(m.key)/\(index)"
            let candidate = localPaths["\(m.thread)/\(m.ts)"] ?? pathCache[cacheKey] ?? a.path
            let resolved: URL? = {
                guard let candidate, FileManager.default.fileExists(atPath: candidate) else { return nil }
                return URL(fileURLWithPath: candidate)
            }()
            if let resolved {
                rememberPath(key: cacheKey, path: resolved.path)
            }
            metas.append(AttachmentMeta(
                filename: a.name,
                mimeType: a.mime,
                byteCount: a.size,
                localURL: resolved
            ))
        }
        return ChatMessage(
            id: id,
            conversationId: m.thread,
            author: SignalAddress(
                uuidString: m.outgoing ? (selfAci ?? "self") : m.sender,
                groupId: isGroup ? m.thread : nil
            ),
            body: m.body.isEmpty ? (metas.isEmpty ? "" : "[attachment]") : m.body,
            direction: m.outgoing ? .outgoing : .incoming,
            status: m.outgoing ? .sent : .delivered,
            sentAt: Date(timeIntervalSince1970: Double(m.ts) / 1000),
            attachments: metas,
            storeTs: m.sts
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
            switch event.type {
            case "message":
                if let msg = event.message {
                    messageCache[msg.key] = msg
                    let cm = chatMessage(msg)
                    // Persist any attachment paths that came from the live download
                    // so they survive across restarts and render immediately.
                    for (idx, att) in msg.attachments.enumerated() {
                        if let path = att.path, !path.isEmpty {
                            let cacheKey = "\(msg.key)/\(idx)"
                            rememberPath(key: cacheKey, path: path)
                            localPaths["\(msg.thread)/\(msg.ts)"] = path
                        }
                    }
                    incomingContinuation.yield(cm)
                }
            case "reaction":
                if let thread = event.thread, let sts = event.targetSts,
                   let emoji = event.emoji, !emoji.isEmpty {
                    onReaction?(thread, sts, emoji, event.remove ?? false, event.senderName ?? "?")
                }
            case "receipt":
                if let kind = event.kind, let stamps = event.timestamps {
                    onReceipt?(event.senderName ?? event.sender ?? "?", kind, stamps)
                }
            default:
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

    private func mimeFor(url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "heic": return "image/heic"
        case "webp": return "image/webp"
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "webm": return "video/webm"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "wav": return "audio/wav"
        case "pdf": return "application/pdf"
        case "txt", "md": return "text/plain"
        case "zip": return "application/zip"
        default: return "application/octet-stream"
        }
    }

    private func fileSize(url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
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
              let t = dlsym(handle, "core_cmd_thread"),
              let a = dlsym(handle, "core_cmd_fetch_attachment"),
              let sa = dlsym(handle, "core_cmd_send_attachment"),
              let sr = dlsym(handle, "core_cmd_send_reply"),
              let sd = dlsym(handle, "core_cmd_send_delete"),
              let se = dlsym(handle, "core_cmd_send_reaction"),
              let srec = dlsym(handle, "core_cmd_send_receipt"),
              let sco = dlsym(handle, "core_cmd_send_call_offer"),
              let sca = dlsym(handle, "core_cmd_send_call_answer"),
              let sci = dlsym(handle, "core_cmd_send_call_ice"),
              let sch = dlsym(handle, "core_cmd_send_call_hangup"),
              let dl = dlsym(handle, "core_cmd_delete_local"),
              let pf = dlsym(handle, "core_cmd_profile"),
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
            threadPage: unsafeBitCast(t, to: (@convention(c) (UnsafePointer<CChar>, UInt64, UInt64) -> UnsafeMutablePointer<CChar>?).self),
            fetchAttachment: unsafeBitCast(a, to: (@convention(c) (UnsafePointer<CChar>, UInt64, UInt64) -> UnsafeMutablePointer<CChar>?).self),
            sendAttachment: unsafeBitCast(sa, to: (@convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int64).self),
            sendReply: unsafeBitCast(sr, to: (@convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>, UInt64, UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int64).self),
            sendDelete: unsafeBitCast(sd, to: (@convention(c) (UnsafePointer<CChar>, UInt64) -> Int64).self),
            sendReaction: unsafeBitCast(se, to: (@convention(c) (UnsafePointer<CChar>, UInt64, UnsafePointer<CChar>, UnsafePointer<CChar>, Int32) -> Int64).self),
            sendReceipt: unsafeBitCast(srec, to: (@convention(c) (UnsafePointer<CChar>, UnsafePointer<UInt64>, UInt64, UnsafePointer<CChar>) -> Int32).self),
            sendCallOffer: unsafeBitCast(sco, to: (@convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int32).self),
            sendCallAnswer: unsafeBitCast(sca, to: (@convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int32).self),
            sendCallIce: unsafeBitCast(sci, to: (@convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafePointer<CChar>, UInt32) -> Int32).self),
            sendCallHangup: unsafeBitCast(sch, to: (@convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int32).self),
            deleteLocal: unsafeBitCast(dl, to: (@convention(c) (UnsafePointer<CChar>, UInt64) -> Int32).self),
            profile: unsafeBitCast(pf, to: (@convention(c) (UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?).self),
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

// MARK: - CallSignalTransport (M4 stub)

extension RustCoreService: CallSignalTransport {
    public func sendCallSignal(_ message: CallSignalMessage) async throws {
        // TODO: M4 - Implement call signaling via RingRTC/websocket
        // For now, log and no-op
        Log.info("Call signal send: \(message.type.rawValue) callId=\(message.callId)")
    }

    public var incomingCallSignals: AsyncStream<CallSignalMessage> {
        AsyncStream { continuation in
            // TODO: M4 - Connect to websocket for incoming call signals
            // For now, empty stream
            continuation.finish()
        }
    }
}

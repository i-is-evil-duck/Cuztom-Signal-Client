import Foundation
import CryptoKit

#if canImport(Darwin)
import Darwin
#endif

#if canImport(Security)
import Security
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
    public struct ReplyReference: Decodable, Sendable {
        public var targetSts: Int64
        public var author: String?
        public var body: String?

        private enum CodingKeys: String, CodingKey {
            case targetSts = "target_sts"
            case author, body
        }
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
        public var replyTo: ReplyReference?
        public var reactions: [String]

        private enum CodingKeys: String, CodingKey {
            case key, thread, sender, body, ts, sts, outgoing, attachments
            case senderName = "sender_name"
            case replyTo = "reply_to"
            case reactions
        }

        public init(
            key: String, thread: String, sender: String, senderName: String,
            body: String, ts: Int64, outgoing: Bool,
            attachments: [WireAttachment] = [], replyTo: ReplyReference? = nil,
            reactions: [String] = []
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
            self.replyTo = replyTo
            self.reactions = reactions
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            key = try c.decode(String.self, forKey: .key)
            thread = try c.decode(String.self, forKey: .thread)
            sender = try c.decode(String.self, forKey: .sender)
            senderName = try c.decodeIfPresent(String.self, forKey: .senderName) ?? "Unknown"
            body = try c.decode(String.self, forKey: .body)
            ts = try c.decode(Int64.self, forKey: .ts)
            // Older snapshots predate sts; fall back to display ts.
            sts = try c.decodeIfPresent(Int64.self, forKey: .sts) ?? ts
            outgoing = try c.decode(Bool.self, forKey: .outgoing)
            attachments = try c.decodeIfPresent([WireAttachment].self, forKey: .attachments) ?? []
            replyTo = try c.decodeIfPresent(ReplyReference.self, forKey: .replyTo)
            reactions = try c.decodeIfPresent([String].self, forKey: .reactions) ?? []
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
    var ambiguous: Bool?
    // typing
    var started: Bool?
    var typingSender: String?
    // edit/delete
    var body: String?

    private enum CodingKeys: String, CodingKey {
        case type, message, thread, emoji, remove, sender, kind, timestamps, body
        case ambiguous
        case targetSts = "target_sts"
        case senderName = "sender_name"
        case started
        case typingSender = "typing_sender"
    }
}

/// M1: `SignalService` backed by `rust-core/` (`presage` Manager) over C FFI.
///
/// Expected C ABI (see `rust-core/src/lib.rs`):
///   `core_cmd_init_encrypted(db_path, passphrase) -> i32`
///       1 linked, 0 fresh, -1 error; ABI 2
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
/// builds/tests on machines without Rust. Native command and poll work is
/// serialized on `SerialNativeExecutor`; the remaining mutable state is
/// protected by the lock-backed boxes and state lock declared below.
public final class RustCoreService: SignalService, @unchecked Sendable {
    public static let expectedNativeABI: UInt32 = 4
    /// The production Signal SFU. Group calls use it unless a staging build
    /// explicitly overrides it, and it is never inferred from the environment.
    public static let defaultSFUURL = "https://sfu.voip.signal.org"
    private static let dylibEnvironmentKey = "CUZTOM_SIGNAL_CORE_PATH"
    private static let dylibHashInfoKey = "CuztomSignalCoreSHA256"
    private static let nativeStoreKeychainAccount = "native.signal.sqlcipher.passphrase.v2"

    private let stateContinuation: AsyncStream<ConnectionState>.Continuation
    public let connectionState: AsyncStream<ConnectionState>

    private let incomingContinuation: AsyncStream<ChatMessage>.Continuation
    private let incoming: AsyncStream<ChatMessage>

    private let libraryBox = NativeLibraryBox()
    public var libraryPath: String? { libraryBox.path }
    private let explicitPath: String?
    private let dbPath: String
    /// Stable namespace for account-bound Swift maps. The native database path
    /// is already account-specific; hashing it avoids putting raw paths in
    /// cache filenames or persisted JSON.
    private let cacheNamespace: String
    private let processState = NativeProcessState.shared
    private let sessionEpoch: SessionEpoch
    private let nativeExecutor = SerialNativeExecutor.shared
    private let lifecycleGate = NativeProcessState.shared.lifecycleGate
    private let stateLock = NSRecursiveLock()
    private let sessionState = NativeSessionStateBox()
    private let pumpBox = PumpTaskBox()
    /// Own ACI (resolved after linking via whoami) for identifying our own messages.
    private var _selfAci: String?
    public var selfAci: String? {
        get { withStateLock { _selfAci } }
        set { withStateLock { _selfAci = newValue } }
    }
    /// Last roster snapshot, keyed by stable wire key (dedupe across refresh).
    private var messageCache: [String: RosterPayload.Message] = [:]
    /// Wire key -> UUID mapping, persisted to prevent duplicate messages on re-sync.
    private var uuidCache: [String: UUID] = [:]
    private var cacheDirectoryURL: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))?.path ?? NSTemporaryDirectory()
        return URL(fileURLWithPath: base)
            .appendingPathComponent("CuztomSignal/CacheScopes/\(cacheNamespace)", isDirectory: true)
    }
    private var uuidCacheURL: URL {
        cacheDirectoryURL.appendingPathComponent("uuid_cache.json")
    }
    private var legacyUUIDCacheURL: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))?.path ?? NSTemporaryDirectory()
        return URL(fileURLWithPath: (base as NSString).appendingPathComponent("CuztomSignal/uuid_cache.json"))
    }
    /// Wire key -> local file path, persisted across launches so roster
    /// re-seeds don't re-download (or re-prompt) every restart.
    private var pathCache: [String: String] = [:]

    private func withStateLock<T>(_ body: () throws -> T) rethrows -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try body()
    }

    private var linkedState: Bool {
        sessionState.linked
    }

    private func setLinkedState(_ value: Bool) {
        sessionState.setLinked(value)
    }

    private var initializedState: Bool {
        sessionState.initialized
    }

    private func setInitializedState(_ value: Bool) {
        sessionState.setInitialized(value)
    }

    private var pathCacheURL: URL {
        cacheDirectoryURL.appendingPathComponent("attachment_paths.json")
    }
    private var legacyPathCacheURL: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))?.path ?? NSTemporaryDirectory()
        return URL(fileURLWithPath: (base as NSString).appendingPathComponent("CuztomSignal/attachment_paths.json"))
    }

    private func loadPathCache() {
        withStateLock {
            // The old un-namespaced map is intentionally not imported: it
            // cannot be proven to belong to this account after a relink.
            guard let data = try? Data(contentsOf: pathCacheURL),
                  let map = try? JSONDecoder().decode([String: String].self, from: data) else { return }
            // Prune entries whose files vanished (cache eviction, reinstalls)
            // and reject paths outside the app-owned media cache.
            pathCache = map.filter { Self.isAllowedCachedPath($0.value) }
        }
    }

    private func savePathCache() {
        withStateLock {
            guard let data = try? JSONEncoder().encode(pathCache) else { return }
            try? FileManager.default.createDirectory(at: cacheDirectoryURL, withIntermediateDirectories: true)
            Self.protectFile(at: cacheDirectoryURL.path)
            try? data.write(to: pathCacheURL, options: .atomic)
            Self.protectFile(at: pathCacheURL.path)
        }
    }

    private func rememberPath(key: String, path: String) {
        withStateLock {
            pathCache[key] = path
            savePathCache()
            Self.protectFile(at: path)
        }
    }

    private func loadUUIDCache() {
        withStateLock {
            guard let data = try? Data(contentsOf: uuidCacheURL),
                  let map = try? JSONDecoder().decode([String: String].self, from: data) else { return }
            uuidCache = map.compactMapValues { UUID(uuidString: $0) }
        }
    }

    private func saveUUIDCache() {
        withStateLock {
            let stringMap = uuidCache.mapValues { $0.uuidString }
            guard let data = try? JSONEncoder().encode(stringMap) else { return }
            try? FileManager.default.createDirectory(at: cacheDirectoryURL, withIntermediateDirectories: true)
            Self.protectFile(at: cacheDirectoryURL.path)
            try? data.write(to: uuidCacheURL, options: .atomic)
            Self.protectFile(at: uuidCacheURL.path)
        }
    }

    /// Local override for on-demand downloads, keyed by message and
    /// attachment index. Keeping the index in the key prevents a message
    /// with multiple files from pointing every attachment at the last file.
    private var localPaths: [String: String] = [:]

    private func localPathKey(thread: String, ts: Int64, index: Int) -> String {
        "\(thread)/\(ts)/\(index)"
    }

    public func bindLocalPath(thread: String, ts: Int64, index: Int = 0, path: String) {
        withStateLock {
            let standardized = URL(fileURLWithPath: path).standardizedFileURL
            guard Self.isAllowedCachedPath(standardized.path) else { return }
            let localKey = localPathKey(thread: thread, ts: ts, index: index)
            localPaths[localKey] = standardized.path
            // `bindLocalPath` is the authoritative path returned by an on-demand
            // download. Persist the same lookup aliases used by roster hydration;
            // otherwise a relaunch loses the manual download and shows Download
            // again even though the file still exists in the cache.
            rememberPath(key: localKey, path: standardized.path)
            rememberPath(key: "\(thread)/\(ts)/self/\(index)", path: standardized.path)
            if let selfAci, !selfAci.isEmpty {
                rememberPath(key: "\(thread)/\(ts)/\(selfAci)/\(index)", path: standardized.path)
            }
        }
    }

    /// Cache a sent attachment locally so it renders immediately and persists across restarts.
    /// Returns the cached file URL.
    public func cacheSentAttachment(thread: String, ts: Int64, sourceURL: URL, filename: String) -> URL {
        withStateLock {
            // Create cache directory
            let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
                .appendingPathComponent("CuztomSignal/attachments", isDirectory: true)
            try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

            // Generate stable cache filename: thread-sanitized-ts-index-filename
            let safeThread = thread.replacingOccurrences(of: ":", with: "_").replacingOccurrences(of: "/", with: "_")
            let safeFilename = URL(fileURLWithPath: filename).lastPathComponent
                .replacingOccurrences(of: "/", with: "_")
            let cacheFilename = "\(safeThread)-\(ts)-0-\(safeFilename)"
            let cacheURL = cacheDir.appendingPathComponent(cacheFilename)

            // Copy file to cache (use security-scoped access if needed)
            let scoped = sourceURL.startAccessingSecurityScopedResource()
            defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }

            try? FileManager.default.removeItem(at: cacheURL)
            if FileManager.default.fileExists(atPath: sourceURL.path) {
                try? FileManager.default.copyItem(at: sourceURL, to: cacheURL)
            } else if let data = try? Data(contentsOf: sourceURL) {
                try? data.write(to: cacheURL)
            }
            Self.protectFile(at: cacheURL.path)

            // Register using the same sender identity that roster messages use.
            // Older builds used the literal "self"; retain that alias so already
            // cached outgoing attachments remain discoverable.
            let sender = selfAci ?? "self"
            let messageKey = "\(thread)/\(ts)/\(sender)"
            let cacheKey = "\(messageKey)/0"
            rememberPath(key: cacheKey, path: cacheURL.path)
            rememberPath(key: "\(thread)/\(ts)/self/0", path: cacheURL.path)
            localPaths[localPathKey(thread: thread, ts: ts, index: 0)] = cacheURL.path

            // Also register with ThreadID-derived key for consistency.
            let threadComponents = ThreadID.parse(thread)
            if let groupKey = threadComponents.groupMasterKey {
                let groupCacheKey = "group:\(groupKey)/\(ts)/\(sender)/0"
                rememberPath(key: groupCacheKey, path: cacheURL.path)
            }

            Log.info("cached sent attachment: \(cacheURL.path)")
            return cacheURL
        }
    }

    public init(libraryPath: String? = nil, dbPath: String? = nil) {
        self.explicitPath = libraryPath
        self.dbPath = dbPath ?? Self.defaultDBPath()
        self.cacheNamespace = Self.cacheNamespace(for: self.dbPath)
        self.sessionEpoch = NativeProcessState.shared.sessionEpoch(databasePath: self.dbPath)
        var sc: AsyncStream<ConnectionState>.Continuation!
        self.connectionState = AsyncStream { sc = $0 }
        self.stateContinuation = sc
        var ic: AsyncStream<ChatMessage>.Continuation!
        self.incoming = AsyncStream { ic = $0 }
        self.incomingContinuation = ic
        if libraryPath != nil {
            _ = loadLibrary()
        }
        loadPathCache()
        loadUUIDCache()
        // Do not retain legacy un-namespaced account maps on disk.
        try? removeIfPresent(legacyPathCacheURL)
        try? removeIfPresent(legacyUUIDCacheURL)
    }

    deinit {
        pumpBox.cancel()
        // The Rust command worker and RingRTC actor are process-wide and may
        // still be finishing callbacks. Never dlclose the dylib from a Swift
        // service deinit; the OS will reclaim it at process exit.
    }

    public static func defaultDBPath() -> String {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))?.path ?? NSTemporaryDirectory()
        return (base as NSString).appendingPathComponent("CuztomSignal/signal.db")
    }

    private static func cacheNamespace(for dbPath: String) -> String {
        let normalized = URL(fileURLWithPath: dbPath).standardizedFileURL.path
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func protectFile(at path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: path
        )
    }

    private static func isAllowedCachedPath(_ path: String) -> Bool {
        let root = (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("CuztomSignal", isDirectory: true)
            .standardizedFileURL.path) ?? ""
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.path
        return !root.isEmpty
            && (candidate == root || candidate.hasPrefix(root + "/"))
            && FileManager.default.fileExists(atPath: candidate)
    }

    public static func defaultSearchPaths() -> [String] {
        var paths: [String] = []
        if let override = ProcessInfo.processInfo.environment[dylibEnvironmentKey],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            paths.append(override)
        }
        if let exeDir = Bundle.main.executableURL?.deletingLastPathComponent().path {
            paths.append((exeDir as NSString).appendingPathComponent("libcuztom_signal_core.dylib"))
        }
        #if DEBUG
        // Development builds may use an explicit Application Support copy,
        // but never infer a path from the process working directory.
        let fm = FileManager.default
        if let appSupport = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false) {
            paths.append(appSupport.appendingPathComponent("CuztomSignal/libcuztom_signal_core.dylib").path)
        }
        #endif
        return paths
    }

    public var isLibraryLoaded: Bool {
        libraryBox.isLoaded
    }

    @discardableResult
    public func loadLibrary() -> Bool {
        do {
            return try nativeExecutor.runSync { [self] in
                loadLibraryOnNativeQueue()
            }
        } catch {
            return false
        }
    }

    private func loadLibraryOnNativeQueue() -> Bool {
        if libraryBox.isLoaded { return true }
        // An explicit path is strict: a missing file means "not available",
        // never silently fall back to a different build (test determinism).
        let paths: [String]
        if let explicitPath {
            paths = [explicitPath]
        } else {
            paths = Self.defaultSearchPaths()
        }
        for path in paths {
            guard let handle = Self.openLibrary(at: path) else { continue }
            if Self.validateLoadedLibrary(handle, at: path) {
                libraryBox.install(handle: handle, path: path)
                return true
            }
            #if canImport(Darwin)
            dlclose(handle)
            #endif
        }
        return false
    }

    private func stopPump() async {
        let pump = pumpBox.take()
        pump?.cancel()
        await pump?.value
    }

    public func beginLinking(deviceName: String) async throws -> LinkQR {
        try await lifecycleGate.run { [self] in
            try await beginLinkingInternal(deviceName: deviceName)
        }
    }

    private func beginLinkingInternal(deviceName: String) async throws -> LinkQR {
        // A suspended service starts a new generation; an active session is
        // first probed without invalidating its event pump.
        let probeToken = try sessionEpoch.resumeIfNeeded()
        let alreadyLinked = try await withCore(token: probeToken, lifecycleOwned: true) { sym in
            try Self.isLinked(sym)
        }
        if alreadyLinked {
            setLinkedState(true)
            throw SignalError.alreadyLinked
        }

        // Starting fresh provisioning is a real account transition. Rotate
        // before begin_link so no pre-link task can publish into the new QR
        // session, and stop the old pump before native teardown/replacement.
        let token = try sessionEpoch.rotate()
        await stopPump()

        let url: String? = try await withCore(token: token, lifecycleOwned: true) { sym in
            // Recheck after the rotation in case another native actor linked
            // the worker while the probe was in flight.
            if try Self.isLinked(sym) { return nil }
            var ptr: UnsafeMutablePointer<CChar>?
            deviceName.withCString { ptr = sym.beginLink($0) }
            guard let ptr else {
                throw SignalError.network("begin_link failed: \(Self.lastError(sym))")
            }
            let value = String(cString: ptr)
            sym.freeString(ptr)
            return value
        }
        guard let url else {
            setLinkedState(true)
            throw SignalError.alreadyLinked
        }
        stateContinuation.yield(.linking)
        setLinkedState(false)
        return LinkQR(payload: url)
    }

    public func waitForLink() async throws {
        let token = try sessionEpoch.capture()
        // Phone scan can take minutes; poll the worker until it resolves.
        let deadline = Date().addingTimeInterval(300)
        while Date() < deadline {
            try Task.checkCancellation()
            let rc: Int32 = try await withCore(token: token) { sym in
                let rc = sym.pollLink()
                if rc < 0 {
                    throw SignalError.network("link failed: \(Self.lastError(sym))")
                }
                return rc
            }
            if rc == 1 {
                try sessionEpoch.withCurrent(token) {
                    setLinkedState(true)
                    stateContinuation.yield(.connected)
                }
                return
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw SignalError.network("link timed out waiting for phone scan")
    }

    public func fetchConversations() async throws -> [Conversation] {
        let token = try sessionEpoch.capture()
        if !linkedState {
            let nativeLinked = try await isLinkedNow(token: token)
            guard nativeLinked else { throw SignalError.notLinked }
        }
        let payload = try JSONDecoder().decode(RosterPayload.self, from: try await rosterData(token: token))
        try sessionEpoch.require(token)
        return try sessionEpoch.withCurrent(token) { applyRoster(payload) }
    }

    /// Get raw roster data for contact resolver population
    public func getRosterData() async throws -> RosterPayload {
        let token = try sessionEpoch.capture()
        if !linkedState {
            let nativeLinked = try await isLinkedNow(token: token)
            guard nativeLinked else { throw SignalError.notLinked }
        }
        let payload = try JSONDecoder().decode(RosterPayload.self, from: try await rosterData(token: token))
        try sessionEpoch.require(token)
        return payload
    }

    public func fetchMessages(conversationId: String, limit: Int) async throws -> [ChatMessage] {
        let token = try sessionEpoch.capture()
        if !linkedState {
            let nativeLinked = try await isLinkedNow(token: token)
            guard nativeLinked else { throw SignalError.notLinked }
        }
        let requestedLimit = max(0, limit)
        // Merge the seed roster with older pages until `limit` is satisfied.
        // `sts` (store clock) is the ONLY correct paging basis — the SQLite
        // range runs over the client timestamp, not the server one.
        // History only goes back to link time: Signal never syncs older
        // messages to a new linked device (protocol limitation, not a bug).
        var cached = try sessionEpoch.withCurrent(token) { threadCache(conversationId) }
        if cached.count < requestedLimit {
            let oldest = cached.map(\.sts).filter { $0 > 0 }.min()
            let before: UInt64 = oldest.map { UInt64(bitPattern: $0) } ?? UInt64.max
            do {
                let page = try await threadPage(token: token, conversationId, limit: requestedLimit, before: before)
                Log.info("thread page \(conversationId): \(page.count) rows before \(before)")
                try sessionEpoch.withCurrent(token) {
                    withStateLock {
                        for m in page { messageCache[m.key] = m }
                    }
                }
                cached = threadCache(conversationId)
            } catch {
                Log.error("thread page failed: \(error)")
                throw error
            }
        }
        return try sessionEpoch.withCurrent(token) {
            let current = threadCache(conversationId)
            return Array(current.suffix(requestedLimit)).map { chatMessage($0) }
        }
    }

    private func threadCache(_ conversationId: String) -> [RosterPayload.Message] {
        withStateLock {
            messageCache.values
                .filter { $0.thread == conversationId }
                .sorted {
                    let left = $0.sts == 0 ? $0.ts : $0.sts
                    let right = $1.sts == 0 ? $1.ts : $1.sts
                    return left == right ? $0.ts < $1.ts : left < right
                }
        }
    }

    private struct ThreadPage: Decodable {
        var messages: [RosterPayload.Message]
    }

    private func threadPage(
        token: SessionToken,
        _ thread: String,
        limit: Int,
        before: UInt64
    ) async throws -> [RosterPayload.Message] {
        let data: Data = try await withCore(token: token) { sym in
            var ptr: UnsafeMutablePointer<CChar>?
            thread.withCString { t in
                ptr = sym.threadPage(t, UInt64(limit), before)
            }
            guard let ptr else {
                throw SignalError.network("thread page failed: \(Self.lastError(sym))")
            }
            defer { sym.freeString(ptr) }
            guard let data = String(cString: ptr).data(using: .utf8) else {
                throw SignalError.storage("thread page is not UTF-8")
            }
            return data
        }
        return try JSONDecoder().decode(ThreadPage.self, from: data).messages
    }

    /// On-demand attachment download for roster-seeded (metadata-only) rows.
    /// `ts` is the store-clock timestamp (see `ChatMessage.storeTs`).
    public func fetchAttachment(thread: String, ts: Int64, index: Int) async throws -> URL {
        let token = try sessionEpoch.capture()
        let path: String = try await withCore(token: token) { sym in
            var ptr: UnsafeMutablePointer<CChar>?
            thread.withCString { t in
                ptr = sym.fetchAttachment(t, UInt64(bitPattern: ts), UInt64(index))
            }
            guard let ptr else {
                throw SignalError.network("attachment fetch failed: \(Self.lastError(sym))")
            }
            defer { sym.freeString(ptr) }
            return String(cString: ptr)
        }
        return URL(fileURLWithPath: path)
    }

    /// Upload a local file and send it. Returns (sent ts, filename, mime, size).
    public func sendAttachment(thread: String, path: String, caption: String) async throws -> (ts: Int64, name: String, mime: String, size: Int) {
        let token = try sessionEpoch.capture()
        let ts: Int64 = try await withCore(token: token) { sym in
            var ts: Int64 = -1
            thread.withCString { t in
                path.withCString { p in
                    caption.withCString { c in
                        ts = sym.sendAttachment(t, p, c)
                    }
                }
            }
            guard ts >= 0 else {
                throw SignalError.network("attachment send failed: \(Self.lastError(sym))")
            }
            return ts
        }
        try sessionEpoch.require(token)
        let url = URL(fileURLWithPath: path)
        return (ts, url.lastPathComponent, mimeFor(url: url), fileSize(url: url))
    }

    /// Reply quoting (`qTs` store-clock, `qAuthor` service id, `qBody`).
    public func sendReply(thread: String, body: String, qTs: Int64, qAuthor: String, qBody: String) async throws -> Int64 {
        let token = try sessionEpoch.capture()
        return try await withCore(token: token) { sym in
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
            guard ts >= 0 else {
                throw SignalError.network("reply failed: \(Self.lastError(sym))")
            }
            return ts
        }
    }

    /// Delete-for-everyone tombstone. Local removal is separate.
    public func sendDeleteTombstone(thread: String, targetTs: Int64) async throws {
        let token = try sessionEpoch.capture()
        try await withCore(token: token) { sym in
            let ts = thread.withCString { t in
                sym.sendDelete(t, UInt64(bitPattern: targetTs))
            }
            guard ts >= 0 else {
                throw SignalError.network("delete send failed: \(Self.lastError(sym))")
            }
        }
    }

    /// Local-only store removal. Returns true when a row existed.
    public func deleteLocal(thread: String, sts: Int64) async throws -> Bool {
        let token = try sessionEpoch.capture()
        return try await withCore(token: token) { sym in
            let rc = thread.withCString { t in
                sym.deleteLocal(t, UInt64(bitPattern: sts))
            }
            guard rc >= 0 else {
                throw SignalError.network("local delete failed: \(Self.lastError(sym))")
            }
            return rc == 1
        }
    }

    /// Toggle/add `emoji` reaction on the message at `targetSts`.
    public func sendReaction(thread: String, targetSts: Int64, author: String, emoji: String, remove: Bool) async throws {
        let token = try sessionEpoch.capture()
        try await withCore(token: token) { sym in
            let ts = thread.withCString { t in
                author.withCString { a in
                    emoji.withCString { e in
                        sym.sendReaction(t, UInt64(bitPattern: targetSts), a, e, remove ? 1 : 0)
                    }
                }
            }
            guard ts >= 0 else {
                throw SignalError.network("reaction failed: \(Self.lastError(sym))")
            }
        }
    }

    /// Send a read/delivery receipt for the given message timestamps (store clocks).
    /// `kind` is "read" or "delivered".
    public func sendReceipt(thread: String, timestamps: [Int64], kind: String) async throws {
        let token = try sessionEpoch.capture()
        let tsArray = timestamps.map { UInt64(bitPattern: $0) }
        try await withCore(token: token) { sym in
            let rc = thread.withCString { t in
                kind.withCString { k in
                    sym.sendReceipt(t, tsArray, UInt64(tsArray.count), k)
                }
            }
            guard rc == 0 else {
                throw SignalError.network("send receipt failed: \(Self.lastError(sym))")
            }
        }
    }

    // MARK: - M3: Message Edits & Typing

    /// Send a message edit (replaces content). Returns sent timestamp (ms).
    public func sendMessageEdit(thread: String, targetTs: Int64, newBody: String) async throws -> Int64 {
        let token = try sessionEpoch.capture()
        return try await withCore(token: token) { sym in
            var ts: Int64 = -1
            thread.withCString { t in
                newBody.withCString { b in
                    ts = sym.sendMessageEdit(t, UInt64(bitPattern: targetTs), b)
                }
            }
            guard ts >= 0 else {
                throw SignalError.network("send message edit failed: \(Self.lastError(sym))")
            }
            return ts
        }
    }

    /// Send a typing indicator.
    public func sendTyping(thread: String, started: Bool) async throws {
        let token = try sessionEpoch.capture()
        try await withCore(token: token) { sym in
            let rc = thread.withCString { t in
                sym.sendTyping(t, started ? 1 : 0)
            }
            guard rc == 0 else {
                throw SignalError.network("send typing failed: \(Self.lastError(sym))")
            }
        }
    }

    // MARK: - M4: Call Signaling

    /// Send a call offer (SDP) to start a call.
    public func sendCallOffer(callId: String, to: String, mediaType: String, sdp: String) async throws {
        let token = try sessionEpoch.capture()
        try await withCore(token: token) { sym in
            let rc = callId.withCString { c in
                to.withCString { t in
                    mediaType.withCString { m in
                        sdp.withCString { s in
                            sym.sendCallOffer(c, t, m, s)
                        }
                    }
                }
            }
            guard rc == 0 else {
                throw SignalError.network("send call offer failed: \(Self.lastError(sym))")
            }
        }
    }

    /// Send a call answer (SDP) to accept a call.
    public func sendCallAnswer(callId: String, sdp: String) async throws {
        let token = try sessionEpoch.capture()
        try await withCore(token: token) { sym in
            let rc = callId.withCString { c in
                sdp.withCString { s in
                    sym.sendCallAnswer(c, s)
                }
            }
            guard rc == 0 else {
                throw SignalError.network("send call answer failed: \(Self.lastError(sym))")
            }
        }
    }

    /// Send an ICE candidate during call setup.
    public func sendCallIceCandidate(callId: String, candidate: String, sdpMid: String, sdpMLineIndex: UInt32) async throws {
        let token = try sessionEpoch.capture()
        try await withCore(token: token) { sym in
            let rc = callId.withCString { c in
                candidate.withCString { cand in
                    sdpMid.withCString { mid in
                        sym.sendCallIce(c, cand, mid, sdpMLineIndex)
                    }
                }
            }
            guard rc == 0 else {
                throw SignalError.network("send call ice failed: \(Self.lastError(sym))")
            }
        }
    }

    /// Send a call hangup.
    public func sendCallHangup(callId: String, reason: String) async throws {
        let token = try sessionEpoch.capture()
        try await withCore(token: token) { sym in
            let rc = callId.withCString { c in
                reason.withCString { r in
                    sym.sendCallHangup(c, r)
                }
            }
            guard rc == 0 else {
                throw SignalError.network("send call hangup failed: \(Self.lastError(sym))")
            }
        }
    }

    // MARK: - Call Signaling Integration (M4)

    // MARK: - Native RingRTC call control

    /// Start a real 1:1 call. Returns RingRTC's numeric call id.
    public func startCall(thread: String, mediaType: String) async throws -> UInt64 {
        let token = try sessionEpoch.capture()
        return try await withCore(token: token) { sym in
            let id = thread.withCString { t in
                mediaType.withCString { m in
                    sym.callStart(t, m)
                }
            }
            guard id != .max else {
                throw SignalError.network("start call failed: \(Self.lastError(sym))")
            }
            return id
        }
    }

    /// Accept a native incoming call.
    public func acceptCall(callId: UInt64) async throws {
        let token = try sessionEpoch.capture()
        try await withCore(token: token) { sym in
            guard sym.callAccept(callId) == 0 else {
                throw SignalError.network("accept call failed: \(Self.lastError(sym))")
            }
        }
    }

    /// Hang up the native active call.
    public func hangupCall() async throws {
        let token = try sessionEpoch.capture()
        try await withCore(token: token) { sym in
            guard sym.callHangup() == 0 else {
                throw SignalError.network("hangup call failed: \(Self.lastError(sym))")
            }
        }
    }

    /// Mute/unmute the native outgoing audio track.
    public func setCallMuted(_ muted: Bool) async throws {
        let token = try sessionEpoch.capture()
        try await withCore(token: token) { sym in
            guard sym.callSetMuted(muted ? 1 : 0) == 0 else {
                throw SignalError.network("set call mute failed: \(Self.lastError(sym))")
            }
        }
    }

    /// One server-issued ZK group auth credential.
    public struct ZkAuthCredential: Sendable, Equatable {
        /// Base64-encoded `AuthCredentialWithPniResponse` protobuf.
        public let credential: String
        public let redemptionTime: UInt64

        public init(credential: String, redemptionTime: UInt64) {
            self.credential = credential
            self.redemptionTime = redemptionTime
        }
    }

    /// The `GET /v1/certificate/auth/group?zkcCredential=true` response.
    public struct GroupAuthCredentials: Sendable, Equatable {
        public let pni: String?
        public let credentials: [ZkAuthCredential]

        public init(pni: String?, credentials: [ZkAuthCredential]) {
            self.pni = pni
            self.credentials = credentials
        }

        /// The credential valid on `day`.
        ///
        /// The server is asked for a *range* of days, so a credential is only
        /// returned when its redemption day actually falls inside the request.
        /// Returning the nearest entry instead would let a stale or
        /// not-yet-valid credential be presented, which the SFU rejects and
        /// which is hard to diagnose.
        public func credential(forDay day: UInt64) -> ZkAuthCredential? {
            credentials.first { $0.redemptionTime / 86_400_000 == day }
        }
    }

    /// Fetch the ZK group auth credentials that a group-call membership proof
    /// is derived from.
    ///
    /// Throws when the account is not linked, the sync loop is not running, or
    /// the response is not the expected shape. No credential is ever
    /// synthesized: a group call without a real credential cannot be made.
    public func groupAuthCredentials() async throws -> GroupAuthCredentials {
        let token = try sessionEpoch.capture()
        return try await withCore(token: token) { sym in
            guard let ptr = sym.groupAuthCredentials() else {
                throw SignalError.network(
                    "group credential fetch failed: \(Self.lastError(sym))"
                )
            }
            defer { sym.freeString(ptr) }
            let json = String(cString: ptr)
            guard let data = json.data(using: .utf8) else {
                throw SignalError.storage("group credential response was not UTF-8")
            }
            return try Self.decodeGroupAuthCredentials(data)
        }
    }

    /// A group's title and the ACIs of its members.
    public struct GroupRoster: Sendable, Equatable, Decodable {
        public let title: String
        public let memberAciUUIDs: [String]
    }

    /// Redeem a group membership proof for a call token at the configured CDN.
    ///
    /// Performed natively because Signal's CDN serves a certificate from
    /// Signal's own authority rather than the system roots: `URLSession` rejects
    /// it, while the native client is already built with the service
    /// configuration's certificate authority. Each configured host is tried in
    /// order; a transport failure moves to the next, and any HTTP status is
    /// returned because that is a real answer.
    ///
    /// The proof travels in the `Authorization` header and is never logged, here
    /// or natively.
    public func groupCallRedeemProof(authorization: String) async throws -> GroupCallProofService.Proof {
        guard !authorization.isEmpty, authorization.contains(":") else {
            throw SignalError.crypto("a membership proof authorization is required")
        }
        let token = try sessionEpoch.capture()
        return try await withCore(token: token) { sym in
            let result = authorization.withCString { value in
                sym.groupCallRedeemProof(value)
            }
            guard let pointer = result else {
                throw SignalError.network(
                    "membership proof redemption failed: \(Self.lastError(sym))"
                )
            }
            defer { sym.freeString(pointer) }
            let json = String(cString: pointer)
            guard let data = json.data(using: .utf8) else {
                throw SignalError.storage("redemption response was not UTF-8")
            }
            struct Payload: Decodable {
                let tokenB64: String
            }
            guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
                  let token = Data(base64Encoded: payload.tokenB64),
                  !token.isEmpty else {
                throw SignalError.network("the call service did not return a group call credential")
            }
            return GroupCallProofService.Proof(groupIdHex: "", token: [UInt8](token))
        }
    }

    /// The CDN base URLs the service configuration declares.
    ///
    /// A group membership proof is redeemed at a CDN, and the host belongs to
    /// the service configuration: it differs between staging and production, and
    /// a hardcoded host fails as an unreachable endpoint rather than as a
    /// configuration mistake. Throws rather than falling back to a guess.
    public func cdnUrls() async throws -> [URL] {
        let token = try sessionEpoch.capture()
        return try await withCore(token: token) { sym in
            guard let pointer = sym.cdnUrls() else {
                throw SignalError.network("no CDN is configured: \(Self.lastError(sym))")
            }
            defer { sym.freeString(pointer) }
            let json = String(cString: pointer)
            guard let data = json.data(using: .utf8) else {
                throw SignalError.storage("CDN list was not UTF-8")
            }
            struct Entry: Decodable {
                let url: String
            }
            guard let entries = try? JSONDecoder().decode([Entry].self, from: data) else {
                throw SignalError.storage("CDN list was malformed")
            }
            // Order is preserved from the service configuration, so the first
            // entry is the one the service lists first.
            return entries.compactMap { URL(string: $0.url) }
        }
    }

    /// Read a group's title and membership.
    ///
    /// A group call needs the member ACIs because the SFU maps the opaque
    /// participant ids in call traffic back to people through this group's
    /// encrypted-UID ciphertexts. Throws when this device is not a member: an
    /// empty roster reads as "you are alone in this group", which is a different
    /// statement and the wrong one.
    public func groupRoster(masterKeyHex: String) async throws -> GroupRoster {
        let key = masterKeyHex.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = try sessionEpoch.capture()
        return try await withCore(token: token) { sym in
            let result = key.withCString { masterKey in sym.groupRoster(masterKey) }
            guard let pointer = result else {
                throw SignalError.network("group roster failed: \(Self.lastError(sym))")
            }
            defer { sym.freeString(pointer) }
            let json = String(cString: pointer)
            guard let data = json.data(using: .utf8) else {
                throw SignalError.storage("group roster was not UTF-8")
            }
            do {
                return try JSONDecoder().decode(GroupRoster.self, from: data)
            } catch {
                throw SignalError.storage("group roster was malformed")
            }
        }
    }

    /// Map each ZK group id this device belongs to back to its master key.
    ///
    /// An inbound group call names a group by identifier, and a call for a group
    /// this device is not in is not receivable, so this is what the host uses to
    /// decide which inbound calls it can answer.
    public func groupIdMap() async throws -> [String: String] {
        let token = try sessionEpoch.capture()
        return try await withCore(token: token) { sym in
            guard let pointer = sym.groupIdMap() else {
                throw SignalError.network("group id map failed: \(Self.lastError(sym))")
            }
            defer { sym.freeString(pointer) }
            let json = String(cString: pointer)
            guard let data = json.data(using: .utf8),
                  let entries = try? JSONDecoder().decode(
                    [GroupIdMapEntry].self,
                    from: data
                  ) else {
                throw SignalError.storage("group id map was malformed")
            }
            return Dictionary(
                entries.map { ($0.groupIdHex, $0.masterKeyHex) },
                uniquingKeysWith: { first, _ in first }
            )
        }
    }

    private struct GroupIdMapEntry: Decodable {
        let groupIdHex: String
        let masterKeyHex: String
    }

    /// A group member as the SFU identifies them.
    public struct GroupMember: Sendable, Equatable {
        /// Raw 16-byte service id.
        public let userId: [UInt8]
        /// This group's encrypted-UID ciphertext for the same member.
        public let memberId: [UInt8]
    }

    /// Derive the ZK group identifier for a group master key.
    ///
    /// A group thread id is `group:<master key hex>`, and RingRTC is keyed on
    /// the derived identifier rather than the key, so the host needs this to
    /// start a call at all. Pure and offline.
    public func groupCallGroupId(masterKeyHex: String) async throws -> String {
        let key = masterKeyHex.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = try sessionEpoch.capture()
        return try await withCore(token: token) { sym in
            let result = key.withCString { masterKey in
                sym.groupCallGroupId(masterKey)
            }
            guard let pointer = result else {
                throw SignalError.network(
                    "group id derivation failed: \(Self.lastError(sym))"
                )
            }
            defer { sym.freeString(pointer) }
            return String(cString: pointer)
        }
    }

    /// Build the member identities the SFU needs to attribute call traffic.
    ///
    /// Without a roster the SFU cannot map the opaque participant ids it
    /// reports back to group members, so a call connects but nobody can be
    /// identified. One invalid service id fails the whole request rather than
    /// producing a partial roster that misattributes traffic silently.
    public func groupCallMemberIdentities(
        masterKeyHex: String,
        memberAciUUIDs: [String]
    ) async throws -> [GroupMember] {
        let key = masterKeyHex.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = try JSONEncoder().encode(memberAciUUIDs)
        let json = String(decoding: payload, as: UTF8.self)
        let token = try sessionEpoch.capture()
        return try await withCore(token: token) { sym in
            let result = key.withCString { masterKey in
                json.withCString { members in
                    sym.groupCallMemberIdentities(masterKey, members)
                }
            }
            guard let pointer = result else {
                throw SignalError.network(
                    "group member identities failed: \(Self.lastError(sym))"
                )
            }
            defer { sym.freeString(pointer) }
            return try Self.decodeGroupMembers(String(cString: pointer))
        }
    }

    /// Wire shape of a member identity. Kept strict for the same reason the
    /// credential response is: an unrecognised entry is rejected rather than
    /// partially read into a roster.
    private struct GroupMemberPayload: Decodable {
        let userId: String
        let memberId: String
    }

    static func decodeGroupMembers(_ json: String) throws -> [GroupMember] {
        guard let data = json.data(using: .utf8) else {
            throw SignalError.storage("group member response was not UTF-8")
        }
        let payloads: [GroupMemberPayload]
        do {
            payloads = try JSONDecoder().decode([GroupMemberPayload].self, from: data)
        } catch {
            throw SignalError.storage("group member response was malformed")
        }
        return try payloads.map { payload in
            guard let userId = Self.decodeHex(payload.userId),
                  let memberId = Self.decodeHex(payload.memberId),
                  userId.count == 16,
                  !memberId.isEmpty else {
                throw SignalError.network("group member identity was malformed")
            }
            return GroupMember(userId: userId, memberId: memberId)
        }
    }

    static func decodeHex(_ text: String) -> [UInt8]? {
        guard text.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    /// Build the CDN authorization for a group call membership proof.
    ///
    /// This is the whole crypto half of a group-call join: it fetches a ZK auth
    /// credential from the service, binds it to this account and the group, and
    /// presents it. The result is the `hex(groupPublicParams):hex(presentation)`
    /// value `GroupCallProofService` redeems at the CDN.
    ///
    /// Throws when the account is not linked, the sync loop is not running, the
    /// group is not one this device belongs to, or the service issued no
    /// credential for today. There is no fallback: without a real credential
    /// there is no proof, and the SFU would reject the join with a diagnostic
    /// that points nowhere near the cause.
    public func groupCallProofAuthorization(groupIdHex: String) async throws -> String {
        let bytes = try Self.groupIdBytes(fromHex: groupIdHex)
        let token = try sessionEpoch.capture()
        return try await withCore(token: token) { sym in
            let result = bytes.withUnsafeBufferPointer { buffer in
                sym.groupCallProofAuthorization(buffer.baseAddress, UInt32(buffer.count))
            }
            guard let pointer = result else {
                throw SignalError.network(
                    "group membership proof unavailable: \(Self.lastError(sym))"
                )
            }
            defer { sym.freeString(pointer) }
            return String(cString: pointer)
        }
    }

    /// Decode a 32-byte group identifier from hex.
    ///
    /// The identifier's length is checked here rather than left to the native
    /// side, so a wrong-length id is a clear Swift error instead of a resolution
    /// failure that scans every local group before reporting.
    static func groupIdBytes(fromHex hex: String) throws -> [UInt8] {
        let normalized = hex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty,
              normalized.count.isMultiple(of: 2) else {
            throw SignalError.network("group id must be hex")
        }
        var bytes = [UInt8]()
        bytes.reserveCapacity(normalized.count / 2)
        var index = normalized.startIndex
        while index < normalized.endIndex {
            let next = normalized.index(index, offsetBy: 2)
            guard let byte = UInt8(normalized[index..<next], radix: 16) else {
                throw SignalError.network("group id must be hex")
            }
            bytes.append(byte)
            index = next
        }
        guard bytes.count == 32 else {
            throw SignalError.network(
                "group id must be 32 bytes, got \(bytes.count)"
            )
        }
        return bytes
    }

    /// Wire shape of the credential response. Kept strict: an unrecognised
    /// document is rejected rather than partially interpreted.
    private struct GroupAuthCredentialsPayload: Decodable {
        struct Entry: Decodable {
            let credential: String
            let redemptionTime: UInt64
        }
        let pni: String?
        let credentials: [Entry]
    }

    static func decodeGroupAuthCredentials(_ data: Data) throws -> GroupAuthCredentials {
        guard let payload = try? JSONDecoder().decode(GroupAuthCredentialsPayload.self, from: data) else {
            throw SignalError.storage("group credential response was not understood")
        }
        return GroupAuthCredentials(
            pni: payload.pni,
            credentials: payload.credentials.map {
                ZkAuthCredential(credential: $0.credential, redemptionTime: $0.redemptionTime)
            }
        )
    }

    /// Wire shape of the native `group_update` event.
    private struct GroupCallUpdateEvent: Decodable {
        let update: String
        let clientId: UInt32
        let state: String?
        let reason: String?

        enum CodingKeys: String, CodingKey {
            case update, state, reason
            case clientId = "client_id"
        }

        /// An unknown update is dropped rather than guessed at, so a newer core
        /// cannot make this build act on a state it does not understand.
        func groupCallUpdate() -> GroupCallUpdate? {
            guard let kind = GroupCallUpdate.Kind(rawValue: update) else { return nil }
            return GroupCallUpdate(
                kind: kind,
                clientId: clientId,
                state: state,
                reason: reason
            )
        }
    }

    /// A live group call, addressed by its RingRTC client id.
    public struct GroupCallHandle: Sendable, Equatable {
        public let clientId: UInt32
        public let groupIdHex: String

        public init(clientId: UInt32, groupIdHex: String) {
            self.clientId = clientId
            self.groupIdHex = groupIdHex
        }
    }

    /// Create a group call and connect it.
    ///
    /// This does not join: joining is a separate step, because the SFU only
    /// admits the client after a membership proof has been presented, and that
    /// proof is requested as a side effect of joining.
    ///
    /// - Parameters:
    ///   - groupIdHex: the group's 32-byte ZK identifier in hex.
    ///   - sfuURL: overrides the production SFU. Prefer `nil` unless testing
    ///     against a staging deployment.
    public func startGroupCall(
        groupIdHex: String,
        sfuURL: String? = nil
    ) async throws -> GroupCallHandle {
        let normalized = groupIdHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty,
              normalized.allSatisfy({ $0.isHexDigit }),
              normalized.count.isMultiple(of: 2) else {
            throw SignalError.network("group id must be hex")
        }
        let token = try sessionEpoch.capture()
        return try await withCore(token: token) { sym in
            let result = normalized.withCString { groupId in
                if let sfuURL {
                    return sfuURL.withCString { url in
                        sym.groupCallStart(groupId, url)
                    }
                }
                // A null pointer selects the production SFU; an empty string
                // would be a caller mistake and is rejected natively.
                return sym.groupCallStart(groupId, nil)
            }
            guard result != UInt64.max, result != 0 else {
                throw SignalError.network(
                    "group call start failed: \(Self.lastError(sym))"
                )
            }
            return GroupCallHandle(
                clientId: UInt32(result - 1),
                groupIdHex: normalized
            )
        }
    }

    /// Ask the SFU to admit the call, which raises the membership-proof request.
    public func joinGroupCall(_ call: GroupCallHandle) async throws {
        let token = try sessionEpoch.capture()
        try await withCore(token: token) { sym in
            guard sym.groupCallJoin(call.clientId) == 0 else {
                throw SignalError.network("group call join failed: \(Self.lastError(sym))")
            }
        }
    }

    /// Leave the SFU but keep the call so it can be rejoined.
    public func leaveGroupCall(_ call: GroupCallHandle) async throws {
        let token = try sessionEpoch.capture()
        try await withCore(token: token) { sym in
            guard sym.groupCallLeave(call.clientId) == 0 else {
                throw SignalError.network("group call leave failed: \(Self.lastError(sym))")
            }
        }
    }

    /// Leave if needed, then end the call and release the native client.
    public func endGroupCall(_ call: GroupCallHandle) async throws {
        let token = try sessionEpoch.capture()
        try await withCore(token: token) { sym in
            guard sym.groupCallEnd(call.clientId) == 0 else {
                throw SignalError.network("group call end failed: \(Self.lastError(sym))")
            }
        }
    }

    /// A state change from a native group call.
    ///
    /// `requestMembershipProof` is the one that matters for actually joining:
    /// RingRTC will not send its SFU join request until a proof is presented, so
    /// the host has to fetch a ZK credential, redeem it at the CDN, and answer
    /// with `groupCallSetMembershipProof(clientId:token:)`.
    public struct GroupCallUpdate: Sendable, Equatable {
        public enum Kind: String, Sendable, Equatable {
            case requestMembershipProof = "request_membership_proof"
            case requestGroupMembers = "request_group_members"
            case connectionStateChanged = "connection_state_changed"
            case joinStateChanged = "join_state_changed"
            case ended
            case reactions
            case raisedHands = "raised_hands"
            case speechEvent = "speech_event"
            case remoteMute = "remote_mute"
            case observedRemoteMute = "observed_remote_mute"
        }

        public let kind: Kind
        public let clientId: UInt32
        public let state: String?
        public let reason: String?

        public init(
            kind: Kind,
            clientId: UInt32,
            state: String? = nil,
            reason: String? = nil
        ) {
            self.kind = kind
            self.clientId = clientId
            self.state = state
            self.reason = reason
        }
    }

    /// A native group call asked the host for something it cannot do itself.
    public var onGroupCallUpdate: ((GroupCallUpdate) -> Void)? {
        get { callbackLock.lock(); defer { callbackLock.unlock() }; return _onGroupCallUpdate }
        set { callbackLock.lock(); _onGroupCallUpdate = newValue; callbackLock.unlock() }
    }

    /// Hand a group-call membership proof to RingRTC.
    ///
    /// This is the step that unblocks the SFU join, so a failure here means the
    /// call cannot connect rather than degrading quietly.
    public func groupCallSetMembershipProof(clientId: UInt32, token: [UInt8]) async throws {
        let tokenSession = try sessionEpoch.capture()
        let proof = token
        try await withCore(token: tokenSession) { sym in
            let rc = proof.withUnsafeBufferPointer { buffer in
                sym.groupCallSetMembershipProof(clientId, buffer.baseAddress, buffer.count)
            }
            guard rc == 0 else {
                throw SignalError.network(
                    "group membership proof rejected: \(Self.lastError(sym))"
                )
            }
        }
    }

    /// Flatten member identities into the C ABI's three parallel buffers.
    ///
    /// Kept as a pure function so the `withCore` closure captures immutable
    /// values, which Swift 6 concurrency requires.
    static func flattenGroupMembers(
        _ members: [(userId: [UInt8], memberId: [UInt8])]
    ) throws -> (userIds: [UInt8], memberLens: [UInt32], memberIds: [UInt8]) {
        var userIds = [UInt8]()
        var memberLens = [UInt32]()
        var memberIds = [UInt8]()
        for (index, member) in members.enumerated() {
            guard member.userId.count == 16, !member.memberId.isEmpty else {
                throw SignalError.network("group member \(index) identity was malformed")
            }
            userIds.append(contentsOf: member.userId)
            memberLens.append(UInt32(member.memberId.count))
            memberIds.append(contentsOf: member.memberId)
        }
        return (userIds, memberLens, memberIds)
    }

    /// Supply the member identities the SFU needs to attribute call traffic.
    ///
    /// Encrypted-UID ciphertexts are variable length, so an explicit length per
    /// member is sent rather than a fixed stride. Malformed entries are
    /// rejected here rather than being passed on to be read out of bounds.
    public func groupCallSetGroupMembers(
        clientId: UInt32,
        members: [(userId: [UInt8], memberId: [UInt8])]
    ) async throws {
        let (userIdBytes, memberLengths, memberIdBytes) =
            try Self.flattenGroupMembers(members)
        let count = UInt32(members.count)
        let memberBytes = UInt32(memberIdBytes.count)
        let token = try sessionEpoch.capture()
        try await withCore(token: token) { sym in
            let rc = userIdBytes.withUnsafeBufferPointer { userBuffer in
                memberLengths.withUnsafeBufferPointer { lengthBuffer in
                    memberIdBytes.withUnsafeBufferPointer { memberBuffer in
                        sym.groupCallSetGroupMembers(
                            clientId,
                            count,
                            userBuffer.baseAddress,
                            lengthBuffer.baseAddress,
                            memberBuffer.baseAddress,
                            memberBytes
                        )
                    }
                }
            }
            guard rc == 0 else {
                throw SignalError.network("group members rejected: \(Self.lastError(sym))")
            }
        }
    }

    /// An SFU request RingRTC raised and handed to the host to perform.
    ///
    /// RingRTC has no HTTP transport in this core, so every SFU request stalls
    /// until `deliverHTTPResponse(requestId:status:body:)` is called. A
    /// `status` of `nil` means the request could not be performed at all.
    public struct PendingHTTPRequest: Sendable, Equatable {
        public let requestId: UInt32
        public let method: String
        public let url: String
        public let headers: [String: String]
        public let body: [UInt8]?

        public init(
            requestId: UInt32,
            method: String,
            url: String,
            headers: [String: String],
            body: [UInt8]?
        ) {
            self.requestId = requestId
            self.method = method
            self.url = url
            self.headers = headers
            self.body = body
        }
    }

    /// Hand an SFU response back to RingRTC.
    ///
    /// This is deliberately not session-token gated: an SFU request is issued
    /// by RingRTC, not by a caller, and a stale request id is simply ignored by
    /// RingRTC. The host still has to be the one that performed the request.
    public func deliverHTTPResponse(requestId: UInt32, status: Int?, body: [UInt8]) async throws {
        let token = try sessionEpoch.capture()
        try await withCore(token: token, allowStale: true, lifecycleOwned: false) { sym in
            let rc = body.withUnsafeBufferPointer { buffer in
                // A null pointer with length 0 is the documented way to say
                // "no body", so an empty response passes nil through.
                guard let base = buffer.baseAddress else {
                    return sym.httpResponse(
                        requestId,
                        status.map { UInt32($0) } ?? 0,
                        nil,
                        0
                    )
                }
                return sym.httpResponse(
                    requestId,
                    status.map { UInt32($0) } ?? 0,
                    base,
                    buffer.count
                )
            }
            guard rc == 0 else {
                throw SignalError.network("SFU response rejected: \(Self.lastError(sym))")
            }
        }
    }

    /// Wire shape of the native `http_request` event.
    private struct PendingHTTPEvent: Decodable {
        let id: UInt32
        let method: String
        let url: String
        let headers: [String: String]?
        let bodyB64: String?

        enum CodingKeys: String, CodingKey {
            case id, method, url, headers
            case bodyB64 = "body_b64"
        }

        /// `nil` when the event is missing something the host needs, so a
        /// malformed event is dropped instead of producing a broken request.
        func pendingRequest() -> PendingHTTPRequest? {
            guard !method.isEmpty, !url.isEmpty,
                  let scheme = URL(string: url)?.scheme?.lowercased(),
                  scheme == "https" else { return nil }
            var body: [UInt8]?
            if let bodyB64, !bodyB64.isEmpty {
                guard let decoded = Data(base64Encoded: bodyB64) else { return nil }
                body = [UInt8](decoded)
            }
            return PendingHTTPRequest(
                requestId: id,
                method: method.uppercased(),
                url: url,
                headers: headers ?? [:],
                body: body
            )
        }
    }

    /// Decode a `group_update` event. Exposed for tests only; the production
    /// path is `drainEvents`, which additionally guards on the session epoch.
    static func decodeGroupCallUpdateForTesting(_ data: Data) -> GroupCallUpdate? {
        guard let event = try? JSONDecoder().decode(GroupCallUpdateEvent.self, from: data) else {
            return nil
        }
        return event.groupCallUpdate()
    }

    /// Decode an `http_request` event. Exposed for tests only; the production
    /// path is `drainEvents`, which additionally guards on the session epoch.
    static func decodePendingHTTPEventForTesting(_ data: Data) -> PendingHTTPRequest? {
        guard let event = try? JSONDecoder().decode(PendingHTTPEvent.self, from: data) else {
            return nil
        }
        return event.pendingRequest()
    }

    /// Send a pre-built call signal (base64-encoded protobuf CallMessage) to a thread.
    public func sendCallSignalRaw(thread: String, callMessageBase64: String) async throws {
        let token = try sessionEpoch.capture()
        try await withCore(token: token) { sym in
            let rc = thread.withCString { t in
                callMessageBase64.withCString { j in
                    sym.sendCallSignal(t, j)
                }
            }
            guard rc == 0 else {
                throw SignalError.network("send call signal failed: \(Self.lastError(sym))")
            }
        }
    }

    /// Build a call offer protobuf. Returns JSON describing the message.
    public func buildCallOffer(callId: String, mediaType: String, opaque: String) async throws -> String {
        let token = try sessionEpoch.capture()
        return try await withCore(token: token) { sym in
            var ptr: UnsafeMutablePointer<CChar>?
            callId.withCString { c in
                mediaType.withCString { m in
                    opaque.withCString { o in
                        ptr = sym.buildCallOffer(c, m, o)
                    }
                }
            }
            return try Self.copyAndFree(ptr, sym: sym, what: "build call offer")
        }
    }

    /// Build a call answer protobuf. Returns JSON describing the message.
    public func buildCallAnswer(callId: String, opaque: String) async throws -> String {
        let token = try sessionEpoch.capture()
        return try await withCore(token: token) { sym in
            var ptr: UnsafeMutablePointer<CChar>?
            callId.withCString { c in
                opaque.withCString { o in
                    ptr = sym.buildCallAnswer(c, o)
                }
            }
            return try Self.copyAndFree(ptr, sym: sym, what: "build call answer")
        }
    }

    /// Build a call ICE protobuf. Returns JSON describing the message.
    public func buildCallIce(callId: String, opaque: String) async throws -> String {
        let token = try sessionEpoch.capture()
        return try await withCore(token: token) { sym in
            var ptr: UnsafeMutablePointer<CChar>?
            callId.withCString { c in
                opaque.withCString { o in
                    ptr = sym.buildCallIce(c, o)
                }
            }
            return try Self.copyAndFree(ptr, sym: sym, what: "build call ice")
        }
    }

    /// Build a call hangup protobuf. Returns JSON describing the message.
    public func buildCallHangup(callId: String, hangupType: UInt32, deviceId: UInt32 = 0) async throws -> String {
        let token = try sessionEpoch.capture()
        return try await withCore(token: token) { sym in
            var ptr: UnsafeMutablePointer<CChar>?
            callId.withCString { c in
                ptr = sym.buildCallHangup(c, hangupType, deviceId)
            }
            return try Self.copyAndFree(ptr, sym: sym, what: "build call hangup")
        }
    }

    /// Build a call busy protobuf. Returns JSON describing the message.
    public func buildCallBusy(callId: String) async throws -> String {
        let token = try sessionEpoch.capture()
        return try await withCore(token: token) { sym in
            var ptr: UnsafeMutablePointer<CChar>?
            callId.withCString { c in
                ptr = sym.buildCallBusy(c)
            }
            return try Self.copyAndFree(ptr, sym: sym, what: "build call busy")
        }
    }

    /// Parse a base64-encoded protobuf CallMessage. Returns JSON describing the parsed signal.
    public func parseCallMessage(base64: String) async throws -> String {
        let token = try sessionEpoch.capture()
        return try await withCore(token: token) { sym in
            var ptr: UnsafeMutablePointer<CChar>?
            base64.withCString { b in
                ptr = sym.parseCallMessage(b)
            }
            return try Self.copyAndFree(ptr, sym: sym, what: "parse call message")
        }
    }

    /// Convert an i32 call end reason to a string.
    public func callEndReasonName(_ reason: Int32) async throws -> String {
        let token = try sessionEpoch.capture()
        return try await withCore(token: token) { sym in
            let ptr = sym.callEndReasonToString(reason)
            return try Self.copyAndFree(ptr, sym: sym, what: "call end reason lookup")
        }
    }

    /// Profile display name for a contact uuid (nil when unavailable).
    public func profileName(uuid: String) async -> String? {
        let token: SessionToken
        do {
            token = try sessionEpoch.capture()
        } catch {
            return nil
        }
        let name: String? = try? await withCore(token: token) { sym in
            var ptr: UnsafeMutablePointer<CChar>?
            uuid.withCString { u in
                ptr = sym.profile(u)
            }
            guard let ptr else { return nil }
            defer { sym.freeString(ptr) }
            let value = String(cString: ptr)
            return value.isEmpty ? nil : value
        }
        return name
    }

    public func sendText(_ body: String, to conversationId: String) async throws -> ChatMessage {
        let token = try sessionEpoch.capture()
        if !linkedState {
            let nativeLinked = try await isLinkedNow(token: token)
            guard nativeLinked else { throw SignalError.notLinked }
        }
        let ts: Int64 = try await withCore(token: token) { sym in
            let ts = conversationId.withCString { t in
                body.withCString { b in
                    sym.send(t, b)
                }
            }
            guard ts >= 0 else {
                throw SignalError.network("send failed: \(Self.lastError(sym))")
            }
            return ts
        }
        let sender = selfAci ?? "self"
        let msg = RosterPayload.Message(
            key: "\(conversationId)/\(ts)/\(sender)",
            thread: conversationId, sender: sender, senderName: "You",
            body: body, ts: ts, outgoing: true
        )
        return try sessionEpoch.withCurrent(token) { chatMessage(msg) }
    }

    public func incomingMessages() -> AsyncStream<ChatMessage> {
        incoming
    }

    /// After link: ask the phone for contact sync, start the receive loop,
    /// and pump events into `incomingMessages()`. Throws only if the loop
    /// itself won't start; a failed contact-sync request is non-fatal.
    public func startLiveSync() async throws {
        try await lifecycleGate.run { [self] in
            try await startLiveSyncInternal()
        }
    }

    private func startLiveSyncInternal() async throws {
        let eventToken = try sessionEpoch.rotate()
        await stopPump()

        let contactsAlreadySynced: Bool = try await withCore(token: eventToken, lifecycleOwned: true) { sym in
            let requestResult = sym.requestContacts()
            guard sym.startSync() == 0 else {
                throw SignalError.network("start sync failed: \(Self.lastError(sym))")
            }
            return requestResult != 0
        }
        try sessionEpoch.withCurrent(eventToken) {
            if contactsAlreadySynced {
                // Non-fatal: contacts may already be synced from a previous run.
                stateContinuation.yield(.syncing)
            }
        }
        pumpBox.set(Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.sessionEpoch.isCurrent(eventToken) else { return }
                await self.drainEvents(token: eventToken)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        })
    }

    /// Offline-safe: opens (or creates) the store and reports whether a
    /// linked session exists. No network traffic. Used by setup/tests.
    public func isLinkedAccount() async throws -> Bool {
        let token = try sessionEpoch.capture()
        return try await withCore(token: token) { sym in
            try Self.isLinked(sym)
        }
    }

    /// Offline identity (aci + number) from the local store. No network.
    public struct WhoAmI: Decodable, Sendable {
        public var aci: String
        public var number: String
    }

    public func whoami() async throws -> WhoAmI {
        let token = try sessionEpoch.capture()
        let data: Data = try await withCore(token: token) { sym in
            guard let ptr = sym.whoami() else {
                throw SignalError.network("whoami failed: \(Self.lastError(sym))")
            }
            defer { sym.freeString(ptr) }
            guard let data = String(cString: ptr).data(using: .utf8) else {
                throw SignalError.storage("whoami is not UTF-8")
            }
            return data
        }
        let identity = try JSONDecoder().decode(WhoAmI.self, from: data)
        try sessionEpoch.require(token)
        return identity
    }

    /// Ask the phone to (re-)send the contact/group sync.
    public func requestContactSync() async throws {
        let token = try sessionEpoch.capture()
        try await withCore(token: token) { sym in
            guard sym.requestContacts() == 0 else {
                throw SignalError.network("request sync failed: \(Self.lastError(sym))")
            }
        }
    }

    /// Partial session logout (registration/session only). Use
    /// `clearAllData()` before replacing accounts so native history and media
    /// cannot survive into the next link.
    public func logout() async throws {
        try await lifecycleGate.run { [self] in
            try await logoutInternal()
        }
    }

    private func logoutInternal() async throws {
        var completed = false
        defer {
            if !completed {
                sessionEpoch.poison()
                processState.markPoisoned(databasePath: dbPath)
            }
        }
        if sessionEpoch.isSuspended || sessionEpoch.isPoisoned {
            completed = true
            return
        }
        if !linkedState {
            withStateLock {
                messageCache = [:]
                uuidCache = [:]
                pathCache = [:]
                localPaths = [:]
                selfAci = nil
                _lastRosterSummary = "never"
            }
            completed = true
            return
        }
        let teardownToken = sessionEpoch.suspend()
        detachCallbacks()
        await stopPump()

        try await withCore(token: teardownToken, allowStale: true, lifecycleOwned: true) { sym in
            guard sym.logout() == 0 else {
                throw SignalError.network("logout failed: \(Self.lastError(sym))")
            }
        }
        setLinkedState(false)
        withStateLock {
            messageCache = [:]
            uuidCache = [:]
            pathCache = [:]
            localPaths = [:]
            selfAci = nil
            _lastRosterSummary = "never"
        }
        try removeIfPresent(cacheDirectoryURL)
        try removeIfPresent(legacyPathCacheURL)
        let cachesRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("CuztomSignal", isDirectory: true)
        if let cachesRoot { try removeIfPresent(cachesRoot) }
        try removeIfPresent(legacyUUIDCacheURL)
        // A successful ordinary logout permits a later explicit relink. If
        // any step above failed, the service remains suspended and poisoned
        // instead of allowing a replacement account to start.
        _ = try sessionEpoch.resume()
        completed = true
    }

    /// Complete data wipe: stop the native session, delete the native store,
    /// then remove account-bound Swift caches. The native worker acknowledges
    /// shutdown before its SQLite handle is released. The service remains
    /// suspended until `beginLinking` explicitly starts a replacement account.
    public func clearAllData() async throws {
        try await lifecycleGate.run { [self] in
            try await clearAllDataInternal()
        }
    }

    private func clearAllDataInternal() async throws {
        var completed = false
        defer {
            if !completed {
                sessionEpoch.poison()
                processState.markPoisoned(databasePath: dbPath)
            }
        }
        let teardownToken = sessionEpoch.suspend()
        detachCallbacks()
        await stopPump()

        _ = try await withCore(
            token: teardownToken,
            allowStale: true,
            lifecycleOwned: true
        ) { sym -> Void in
            guard let wipe = sym.wipe else {
                throw SignalError.unsupported(
                    "native core lacks acknowledged shutdown/wipe; rebuild rust-core before retrying"
                )
            }
            guard wipe() == 0 else {
                throw SignalError.storage("native data wipe failed: \(Self.lastError(sym))")
            }
        }

        try removeIfPresent(cacheDirectoryURL)
        try removeIfPresent(legacyPathCacheURL)
        let cachesRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("CuztomSignal", isDirectory: true)
        if let cachesRoot { try removeIfPresent(cachesRoot) }
        try removeIfPresent(legacyUUIDCacheURL)
        #if canImport(Security)
        // The key is account-bound to the wiped native store. Delete it only
        // after the database wipe and all Swift cache removal succeeded.
        try KeychainSecretStore().deleteStrict(key: Self.nativeStoreKeychainAccount)
        // The presentation store's key is wiped separately, and this process may
        // have cached it. A relink must re-read the Keychain rather than reuse
        // this process's copy of a key that no longer matches any database.
        KeychainSecretStore.invalidateResolvedSecrets()
        #endif

        setInitializedState(false)
        setLinkedState(false)
        withStateLock {
            messageCache = [:]
            uuidCache = [:]
            pathCache = [:]
            localPaths = [:]
            _lastRosterSummary = "never"
            selfAci = nil
        }
        processState.clearPoison(databasePath: dbPath)
        completed = true
        Log.info("RustCoreService: cleared all data (native DB and Swift caches)")
    }

    /// Called when the native wipe succeeded but the presentation store could
    /// not be destroyed. The combined logout must not allow a relink on the
    /// same native service after that partial failure.
    func poisonAfterPresentationFailure() {
        sessionEpoch.poison()
        processState.markPoisoned(databasePath: dbPath)
    }

    private func removeIfPresent(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    // MARK: - private FFI

    private struct Symbols: @unchecked Sendable {
        let abiVersion: @convention(c) () -> UInt32
        let initEncrypted: @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int32
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
        let sendMessageEdit: @convention(c) (UnsafePointer<CChar>, UInt64, UnsafePointer<CChar>) -> Int64
        let sendTyping: @convention(c) (UnsafePointer<CChar>, Int32) -> Int32
        let sendCallOffer: @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int32
        let sendCallAnswer: @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int32
        let sendCallIce: @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafePointer<CChar>, UInt32) -> Int32
        let sendCallHangup: @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int32
        let callStart: @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> UInt64
        let callAccept: @convention(c) (UInt64) -> Int32
        let callHangup: @convention(c) () -> Int32
        let callSetMuted: @convention(c) (Int32) -> Int32
        let httpResponse: @convention(c) (UInt32, UInt32, UnsafePointer<UInt8>?, Int) -> Int32
        let groupAuthCredentials: @convention(c) () -> UnsafeMutablePointer<CChar>?
        let groupRoster: @convention(c) (UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
        let cdnUrls: @convention(c) () -> UnsafeMutablePointer<CChar>?
        let groupCallRedeemProof: @convention(c) (UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
        let groupIdMap: @convention(c) () -> UnsafeMutablePointer<CChar>?
        let groupCallProofAuthorization: @convention(c) (UnsafePointer<UInt8>?, UInt32) -> UnsafeMutablePointer<CChar>?
        let groupCallGroupId: @convention(c) (UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
        let groupCallMemberIdentities: @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
        let groupCallSetMembershipProof: @convention(c) (UInt32, UnsafePointer<UInt8>?, Int) -> Int32
        let groupCallSetGroupMembers: @convention(c) (UInt32, UInt32, UnsafePointer<UInt8>?, UnsafePointer<UInt32>?, UnsafePointer<UInt8>?, UInt32) -> Int32
        let groupCallStart: @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UInt64
        let groupCallJoin: @convention(c) (UInt32) -> Int32
        let groupCallLeave: @convention(c) (UInt32) -> Int32
        let groupCallEnd: @convention(c) (UInt32) -> Int32
        // Call signaling integration
        let sendCallSignal: @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int32
        let buildCallOffer: @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
        let buildCallAnswer: @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
        let buildCallIce: @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
        let buildCallHangup: @convention(c) (UnsafePointer<CChar>, UInt32, UInt32) -> UnsafeMutablePointer<CChar>?
        let buildCallBusy: @convention(c) (UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
        let parseCallMessage: @convention(c) (UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
        let callEndReasonToString: @convention(c) (Int32) -> UnsafeMutablePointer<CChar>?
        let deleteLocal: @convention(c) (UnsafePointer<CChar>, UInt64) -> Int32
        let profile: @convention(c) (UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
        let whoami: @convention(c) () -> UnsafeMutablePointer<CChar>?
        let logout: @convention(c) () -> Int32
        /// Required for authoritative data wipe; older dylibs fail closed.
        let wipe: (@convention(c) () -> Int32)?
        let lastError: @convention(c) () -> UnsafePointer<CChar>?
        let freeString: @convention(c) (UnsafeMutablePointer<CChar>?) -> Void
    }

    private let callbackLock = NSLock()
    private var _onSyncEvent: ((String) -> Void)?
    private var _onCallSignal: ((CallSignal) -> Void)?
    private var _onCallState: ((CallStateEvent) -> Void)?
    private var _onHTTPRequest: ((PendingHTTPRequest) -> Void)?
    private var _onGroupCallUpdate: ((GroupCallUpdate) -> Void)?
    private var _onGroupCallSignal: ((GroupCallSignalEvent) -> Void)?
    private var _onReaction: ((String, Int64, String, Bool, String) -> Void)?
    private var _onReceipt: ((String, String, [Int64]) -> Void)?
    private var _onReceiptScoped: ((String?, String, String, [Int64]) -> Void)?
    private var _onTyping: ((String, String, Bool) -> Void)?
    private var _onTypingWithID: ((String, String, String, Bool) -> Void)?
    private var _onEdit: ((String, Int64, String, String, String) -> Void)?
    private var _onDelete: ((String, Int64, String, String) -> Void)?

    /// Non-message sync traffic ("queue_empty", "contacts_synced",
    /// "sync_error:…"). Fires on an internal task — hop threads as needed.
    public var onSyncEvent: ((String) -> Void)? {
        get { callbackLock.lock(); defer { callbackLock.unlock() }; return _onSyncEvent }
        set { callbackLock.lock(); _onSyncEvent = newValue; callbackLock.unlock() }
    }

    /// Native RingRTC signaling/state callbacks. They are invoked on the
    /// service pump task; callers should hop to their own actor if needed.
    public var onCallSignal: ((CallSignal) -> Void)? {
        get { callbackLock.lock(); defer { callbackLock.unlock() }; return _onCallSignal }
        set { callbackLock.lock(); _onCallSignal = newValue; callbackLock.unlock() }
    }
    public var onCallState: ((CallStateEvent) -> Void)? {
        get { callbackLock.lock(); defer { callbackLock.unlock() }; return _onCallState }
        set { callbackLock.lock(); _onCallState = newValue; callbackLock.unlock() }
    }
    /// An inbound group call signal.
    ///
    /// A separate callback from `onCallSignal` because a group message is not 1:1
    /// signaling: it has no thread, no call id, and RingRTC parses it itself. It
    /// is also never a chat row, so it must not reach the message path.
    public var onGroupCallSignal: ((GroupCallSignalEvent) -> Void)? {
        get { callbackLock.lock(); defer { callbackLock.unlock() }; return _onGroupCallSignal }
        set { callbackLock.lock(); _onGroupCallSignal = newValue; callbackLock.unlock() }
    }
    /// An SFU request that RingRTC raised and is blocked on. The host performs
    /// it and responds with `deliverHTTPResponse(requestId:status:body:)`.
    public var onHTTPRequest: ((PendingHTTPRequest) -> Void)? {
        get { callbackLock.lock(); defer { callbackLock.unlock() }; return _onHTTPRequest }
        set { callbackLock.lock(); _onHTTPRequest = newValue; callbackLock.unlock() }
    }

    /// Live reaction: (thread, target store-ts, emoji, remove, sender name).
    public var onReaction: ((String, Int64, String, Bool, String) -> Void)? {
        get { callbackLock.lock(); defer { callbackLock.unlock() }; return _onReaction }
        set { callbackLock.lock(); _onReaction = newValue; callbackLock.unlock() }
    }

    /// Live receipt: (sender name, "read"|"delivered", message timestamps).
    public var onReceipt: ((String, String, [Int64]) -> Void)? {
        get { callbackLock.lock(); defer { callbackLock.unlock() }; return _onReceipt }
        set { callbackLock.lock(); _onReceipt = newValue; callbackLock.unlock() }
    }

    /// Live receipt scoped to a direct-contact thread when the native
    /// envelope exposes one: (thread, sender ID, kind, timestamps).
    public var onReceiptScoped: ((String?, String, String, [Int64]) -> Void)? {
        get { callbackLock.lock(); defer { callbackLock.unlock() }; return _onReceiptScoped }
        set { callbackLock.lock(); _onReceiptScoped = newValue; callbackLock.unlock() }
    }

    public var onTyping: ((String, String, Bool) -> Void)? {
        get { callbackLock.lock(); defer { callbackLock.unlock() }; return _onTyping }
        set { callbackLock.lock(); _onTyping = newValue; callbackLock.unlock() }
    }

    /// Live typing with stable sender identity: (thread, sender ID, name, started).
    public var onTypingWithID: ((String, String, String, Bool) -> Void)? {
        get { callbackLock.lock(); defer { callbackLock.unlock() }; return _onTypingWithID }
        set { callbackLock.lock(); _onTypingWithID = newValue; callbackLock.unlock() }
    }

    /// Live edit: (thread, target store timestamp, body, sender ID, sender name).
    public var onEdit: ((String, Int64, String, String, String) -> Void)? {
        get { callbackLock.lock(); defer { callbackLock.unlock() }; return _onEdit }
        set { callbackLock.lock(); _onEdit = newValue; callbackLock.unlock() }
    }

    /// Live delete: (thread, target store timestamp, sender ID, sender name).
    public var onDelete: ((String, Int64, String, String) -> Void)? {
        get { callbackLock.lock(); defer { callbackLock.unlock() }; return _onDelete }
        set { callbackLock.lock(); _onDelete = newValue; callbackLock.unlock() }
    }

    private func detachCallbacks() {
        callbackLock.lock()
        _onSyncEvent = nil
        _onCallSignal = nil
        _onCallState = nil
        _onHTTPRequest = nil
        _onGroupCallUpdate = nil
        _onGroupCallSignal = nil
        _onReaction = nil
        _onReceipt = nil
        _onReceiptScoped = nil
        _onTyping = nil
        _onTypingWithID = nil
        _onEdit = nil
        _onDelete = nil
        callbackLock.unlock()
    }

    /// "12 contacts, 3 groups, 45 msgs @ 22:01" or "never".
    private var _lastRosterSummary = "never"
    public var lastRosterSummary: String {
        withStateLock { _lastRosterSummary }
    }

    /// Fetch + cache the roster snapshot; returns decoded conversations.
    @discardableResult
    public func applyRoster(_ payload: RosterPayload) -> [Conversation] {
        withStateLock {
            for m in payload.messages {
                messageCache[wireKey(for: m)] = m
            }
            let fmt = DateFormatter()
            fmt.dateFormat = "HH:mm:ss"
            _lastRosterSummary = "\(payload.contacts.count) contacts, \(payload.groups.count) groups, \(payload.messages.count) msgs @ \(fmt.string(from: Date()))"
            var byThread: [String: [RosterPayload.Message]] = [:]
            for m in messageCache.values {
                byThread[m.thread, default: []].append(m)
            }
            var convs: [Conversation] = []
            let selfID = payload.thisDevice.aci.lowercased()
            for c in payload.contacts {
                let id = ThreadID.contactThreadId(uuid: c.id)
                let isSelf = c.id.lowercased() == selfID
                let title: String
                if isSelf {
                    // Signal's roster includes our own profile as a contact. It
                    // is the Note to Self conversation, not a second contact.
                    title = "Note to Self"
                } else {
                    title = c.name.isEmpty ? (c.phone.isEmpty ? "Unknown" : c.phone) : c.name
                }
                let recent = (byThread[id] ?? []).sorted { $0.ts < $1.ts }
                convs.append(Conversation(
                    id: id,
                    title: title,
                    peer: SignalAddress(uuidString: c.id, phone: c.phone.isEmpty ? nil : c.phone, threadId: id),
                    lastMessagePreview: recent.last.map { String($0.body.prefix(120)) },
                    lastActiveAt: recent.last.map { Date(timeIntervalSince1970: Double($0.ts) / 1000) } ?? Date.distantPast,
                    unreadCount: 0
                ))
            }
            for g in payload.groups {
                let id = ThreadID.groupThreadId(masterKey: g.id)
                let recent = (byThread[id] ?? []).sorted { $0.ts < $1.ts }
                convs.append(Conversation(
                    id: id,
                    title: g.title.isEmpty ? "Unnamed group" : g.title,
                    peer: SignalAddress(groupId: g.id, threadId: id),
                    lastMessagePreview: recent.last.map { String($0.body.prefix(120)) },
                    lastActiveAt: recent.last.map { Date(timeIntervalSince1970: Double($0.ts) / 1000) } ?? Date.distantPast,
                    unreadCount: 0
                ))
            }
            return convs.sorted { $0.lastActiveAt > $1.lastActiveAt }
        }
    }

    private func wireKey(for message: RosterPayload.Message) -> String {
        let timestamp = message.sts != 0 ? message.sts : message.ts
        return "\(message.thread)/\(timestamp)/\(message.sender)"
    }

    private func uuidForMessage(_ message: RosterPayload.Message) -> UUID {
        withStateLock {
            let key = wireKey(for: message)
            if let existing = uuidCache[key] {
                return existing
            }
            // Migrate UUIDs written by releases that keyed messages by the
            // server timestamp. The new key uses the stable client timestamp;
            // without this alias the first post-upgrade refresh would allocate
            // a second local ID for every historical message.
            let legacyKeys = [
                "\(message.thread)/\(message.ts)/\(message.sender)",
                "\(message.thread)/\(message.ts)/self"
            ]
            if let legacyKey = legacyKeys.first(where: { uuidCache[$0] != nil }),
               let existing = uuidCache[legacyKey] {
                uuidCache[key] = existing
                if message.key != key { uuidCache[message.key] = existing }
                saveUUIDCache()
                return existing
            }
            let fresh = UUID()
            uuidCache[key] = fresh
            if message.key != key { uuidCache[message.key] = fresh }
            saveUUIDCache()
            return fresh
        }
    }

    public func chatMessage(_ m: RosterPayload.Message) -> ChatMessage {
        withStateLock {
            let id = uuidForMessage(m)
            let threadComponents = ThreadID.parse(m.thread)
            let groupMasterKey = threadComponents.groupMasterKey
            let replyTo = m.replyTo.map {
                MessageReference(
                    storeTs: $0.targetSts,
                    authorID: $0.author,
                    body: $0.body
                )
            }
            var metas: [AttachmentMeta] = []
            for (index, a) in m.attachments.enumerated() {
                // Newest source wins: live/on-demand override, then persisted
                // cache, then the wire path. Cache keys are per-attachment.
                let cacheKey = "\(wireKey(for: m))/\(index)"
                let legacyCacheKey = "\(m.key)/\(index)"
                let stablePathKey = localPathKey(thread: m.thread, ts: m.sts, index: index)
                let legacyTsPathKey = localPathKey(thread: m.thread, ts: m.ts, index: index)
                let candidate = localPaths[stablePathKey]
                    ?? localPaths[legacyTsPathKey]
                    ?? pathCache[cacheKey]
                    ?? pathCache[legacyCacheKey]
                    ?? pathCache["\(m.thread)/\(m.ts)/\(index)"]
                    ?? pathCache["\(m.thread)/\(m.ts)/\(m.sender)/\(index)"]
                    ?? pathCache["\(m.thread)/\(m.ts)/self/\(index)"]
                    ?? pathCache["\(m.thread)/\(m.sts)/\(index)"]
                    ?? a.path
                let resolved: URL? = {
                    guard let candidate, Self.isAllowedCachedPath(candidate) else { return nil }
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
                    groupId: groupMasterKey,
                    threadId: m.thread,
                    displayName: m.outgoing ? nil : (
                        m.senderName.isEmpty
                            || m.senderName == "Unknown"
                            || m.senderName == String(m.sender.prefix(8))
                            ? nil
                            : m.senderName
                    )
                ),
                body: m.body.isEmpty ? (metas.isEmpty ? "" : "[attachment]") : m.body,
                direction: m.outgoing ? .outgoing : .incoming,
                status: m.outgoing ? .sent : .delivered,
                sentAt: Date(timeIntervalSince1970: Double(m.ts) / 1000),
                attachments: metas,
                replyTo: replyTo,
                storeTs: m.sts,
                reactions: m.reactions
            )
        }
    }

    private func rosterData(token: SessionToken) async throws -> Data {
        try await withCore(token: token) { sym in
            guard let ptr = sym.roster() else {
                throw SignalError.network("roster failed: \(Self.lastError(sym))")
            }
            defer { sym.freeString(ptr) }
            guard let data = String(cString: ptr).data(using: .utf8) else {
                throw SignalError.storage("roster is not UTF-8")
            }
            return data
        }
    }

    private func drainEvents(token: SessionToken) async {
        while sessionEpoch.isCurrent(token) && !Task.isCancelled {
            let text: String?
            do {
                text = try await withCore(token: token) { sym in
                    guard let ptr = sym.pollEvent() else { return nil }
                    defer { sym.freeString(ptr) }
                    return String(cString: ptr)
                }
            } catch {
                return
            }
            guard let text else { return }
            guard let data = text.data(using: .utf8),
                  let event = try? JSONDecoder().decode(LiveEvent.self, from: data),
                  sessionEpoch.isCurrent(token) else { continue }

            if event.type == "call_signal" {
                if let signal = try? JSONDecoder().decode(CallSignal.self, from: data),
                   sessionEpoch.isCurrent(token) {
                    onCallSignal?(signal)
                }
                continue
            }
            if event.type == "call_state" {
                if let state = try? JSONDecoder().decode(CallStateEvent.self, from: data),
                   sessionEpoch.isCurrent(token) {
                    onCallState?(state)
                }
                continue
            }
            if event.type == "http_request" {
                // RingRTC raised an SFU request and is now blocked on it. The
                // host performs it and calls back with the response.
                if let request = try? JSONDecoder().decode(PendingHTTPEvent.self, from: data),
                   sessionEpoch.isCurrent(token),
                   let pending = request.pendingRequest() {
                    onHTTPRequest?(pending)
                }
                continue
            }
            if event.type == "group_call_signal" {
                if let signal = try? JSONDecoder().decode(GroupCallSignalEvent.self, from: data),
                   sessionEpoch.isCurrent(token) {
                    onGroupCallSignal?(signal)
                }
                continue
            }
            if event.type == "group_update" {
                if let update = try? JSONDecoder().decode(GroupCallUpdateEvent.self, from: data),
                   sessionEpoch.isCurrent(token),
                   let groupUpdate = update.groupCallUpdate() {
                    onGroupCallUpdate?(groupUpdate)
                }
                continue
            }
            switch event.type {
            case "message":
                guard let msg = event.message else { continue }
                do {
                    let cm = try sessionEpoch.withCurrent(token) { () -> ChatMessage in
                        withStateLock {
                            messageCache[wireKey(for: msg)] = msg
                            let converted = chatMessage(msg)
                            // Persist live attachment paths in the account-scoped
                            // cache before publishing the message.
                            for (idx, att) in msg.attachments.enumerated() {
                                if let path = att.path, !path.isEmpty {
                                    let cacheKey = "\(wireKey(for: msg))/\(idx)"
                                    rememberPath(key: cacheKey, path: path)
                                    if msg.key != wireKey(for: msg) {
                                        rememberPath(key: "\(msg.key)/\(idx)", path: path)
                                    }
                                    localPaths[localPathKey(thread: msg.thread, ts: msg.sts, index: idx)] = path
                                    if msg.sts != msg.ts {
                                        localPaths[localPathKey(thread: msg.thread, ts: msg.ts, index: idx)] = path
                                    }
                                }
                            }
                            return converted
                        }
                    }
                    if sessionEpoch.isCurrent(token) {
                        incomingContinuation.yield(cm)
                    }
                } catch SignalError.sessionInvalidated {
                    return
                } catch {
                    Log.error("live message commit failed: \(error)")
                }
            case "reaction":
                if let thread = event.thread, let sts = event.targetSts,
                   let emoji = event.emoji, !emoji.isEmpty,
                   sessionEpoch.isCurrent(token) {
                    onReaction?(thread, sts, emoji, event.remove ?? false, event.senderName ?? "?")
                }
            case "typing":
                if let thread = event.thread,
                   let sender = event.typingSender,
                   let started = event.started,
                   sessionEpoch.isCurrent(token) {
                    onTypingWithID?(thread, sender, event.senderName ?? sender, started)
                    onTyping?(thread, event.senderName ?? sender, started)
                }
            case "receipt":
                if event.ambiguous == true {
                    Log.error("receipt dropped: target timestamp matched multiple conversations")
                } else if let kind = event.kind, let stamps = event.timestamps,
                          sessionEpoch.isCurrent(token) {
                    let sender = event.sender ?? event.senderName ?? "?"
                    if let scoped = onReceiptScoped {
                        scoped(event.thread, sender, kind, stamps)
                    } else {
                        onReceipt?(sender, kind, stamps)
                    }
                }
            case "edit":
                if let thread = event.thread,
                   let sts = event.targetSts,
                   let body = event.body,
                   sessionEpoch.isCurrent(token) {
                    onEdit?(thread, sts, body, event.sender ?? "?", event.senderName ?? "?")
                }
            case "delete":
                if let thread = event.thread, let sts = event.targetSts,
                   sessionEpoch.isCurrent(token) {
                    onDelete?(thread, sts, event.sender ?? "?", event.senderName ?? "?")
                }
            default:
                if sessionEpoch.isCurrent(token) {
                    onSyncEvent?(event.type)
                }
            }
        }
    }

    private func withCore<T: Sendable>(
        token: SessionToken,
        allowStale: Bool = false,
        lifecycleOwned: Bool = false,
        _ operation: @escaping @Sendable (Symbols) throws -> T
    ) async throws -> T {
        if lifecycleOwned {
            return try await withCoreOnExecutor(
                token: token,
                allowStale: allowStale,
                operation
            )
        }
        return try await lifecycleGate.run { [self] in
            try await self.withCoreOnExecutor(
                token: token,
                allowStale: allowStale,
                operation
            )
        }
    }

    private func withCoreOnExecutor<T: Sendable>(
        token: SessionToken,
        allowStale: Bool,
        _ operation: @escaping @Sendable (Symbols) throws -> T
    ) async throws -> T {
        try processState.requireUsable(databasePath: dbPath)
        if !allowStale { try sessionEpoch.require(token) }
        return try await nativeExecutor.run { [self] in
            try self.processState.requireUsable(databasePath: self.dbPath)
            if !allowStale { try self.sessionEpoch.require(token) }
            let sym = try self.coreSymbolsOnNativeQueue()
            let result = try operation(sym)
            if !allowStale { try self.sessionEpoch.require(token) }
            return result
        }
    }

    /// Must only be called from `nativeExecutor` (or during construction).
    private func coreSymbolsOnNativeQueue() throws -> Symbols {
        guard loadLibrary(), let handle = libraryBox.handle else {
            throw SignalError.unsupported("rust core not bundled — build it: cd rust-core && cargo build --release (see rust-core/README)")
        }
        guard let sym = Self.resolve(in: handle) else {
            throw SignalError.crypto("rust core dylib missing expected symbols (rebuild rust-core/)")
        }
        let rc = try initializeCoreIfNeeded(sym)
        if rc < 0 { throw SignalError.storage("core init failed: \(Self.lastError(sym))") }
        if !initializedState {
            setInitializedState(true)
            setLinkedState(rc == 1)
        }
        return sym
    }

    private func initializeCoreIfNeeded(_ sym: Symbols) throws -> Int32 {
        try sessionState.withLock {
            if initializedState { return linkedState ? 1 : 0 }

        #if canImport(Security)
        let keychain = KeychainSecretStore()
        let keyData: Data
        do {
            let existing = try keychain.loadStrict(key: Self.nativeStoreKeychainAccount)
            if let existing {
                guard existing.count == 32 else {
                    throw SignalError.storage("native database key has an invalid length")
                }
                keyData = existing
            } else {
                // Never create replacement material for an existing
                // encrypted/unknown database. That would make recovery
                // impossible and could silently strand an account.
                guard Self.canCreateNativeDatabaseKey(at: dbPath) else {
                    throw SignalError.storage(
                        "native database key is missing for an existing database; restore Keychain access before relinking"
                    )
                }
                keyData = try keychain.loadOrCreateRandom(
                    key: Self.nativeStoreKeychainAccount,
                    count: 32
                )
            }
        } catch let error as SignalError {
            throw error
        } catch {
            throw SignalError.storage("native database keychain: \(error)")
        }
        let passphrase = keyData.base64EncodedString()
        let rc: Int32 = dbPath.withCString { dbPointer in
            passphrase.withCString { keyPointer in
                sym.initEncrypted(dbPointer, keyPointer)
            }
        }
        if rc < 0 { throw SignalError.storage("core init failed: \(Self.lastError(sym))") }
        setInitializedState(true)
        setLinkedState(rc == 1)
        Self.protectFile(at: dbPath)
        Self.protectFile(at: dbPath + "-wal")
        Self.protectFile(at: dbPath + "-shm")
        return rc
        #else
        throw SignalError.unsupported("SQLCipher requires macOS Security/Keychain support")
        #endif
        }
    }

    private static func canCreateNativeDatabaseKey(at path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return true }
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return false
        }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 16), header.count == 16 else {
            return false
        }
        return header == Data([0x53, 0x51, 0x4C, 0x69, 0x74, 0x65, 0x20, 0x66, 0x6F, 0x72, 0x6D, 0x61, 0x74, 0x20, 0x33, 0x00])
    }

    private func isLinkedNow(token: SessionToken) async throws -> Bool {
        try await withCore(token: token) { sym in
            try Self.isLinked(sym)
        }
    }

    private static func isLinked(_ sym: Symbols) throws -> Bool {
        let result = sym.isLinked()
        guard result >= 0 else {
            throw SignalError.network("is_linked failed: \(lastError(sym))")
        }
        return result == 1
    }

    private static func lastError(_ sym: Symbols) -> String {
        guard let ptr = sym.lastError() else { return "unknown" }
        return String(cString: ptr)
    }

    private static func copyAndFree(
        _ ptr: UnsafeMutablePointer<CChar>?,
        sym: Symbols,
        what: String
    ) throws -> String {
        guard let ptr else {
            throw SignalError.network("\(what) failed: \(lastError(sym))")
        }
        let value = String(cString: ptr)
        sym.freeString(ptr)
        return value
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

    private static func resolve(in handle: UnsafeMutableRawPointer) -> Symbols? {
        #if canImport(Darwin)
        let wp = dlsym(handle, "core_cmd_wipe")
        guard let abi = dlsym(handle, "core_abi_version"),
              let i = dlsym(handle, "core_cmd_init_encrypted"),
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
              let sme = dlsym(handle, "core_cmd_send_message_edit"),
              let sty = dlsym(handle, "core_cmd_send_typing"),
              let sco = dlsym(handle, "core_cmd_send_call_offer"),
              let sca = dlsym(handle, "core_cmd_send_call_answer"),
              let sci = dlsym(handle, "core_cmd_send_call_ice"),
              let sch = dlsym(handle, "core_cmd_send_call_hangup"),
              let cst = dlsym(handle, "core_cmd_call_start"),
              let cac = dlsym(handle, "core_cmd_call_accept"),
              let cah = dlsym(handle, "core_cmd_call_hangup"),
              let csm = dlsym(handle, "core_cmd_call_set_muted"),
              let chr = dlsym(handle, "core_cmd_http_response"),
              let cgac = dlsym(handle, "core_cmd_group_auth_credentials"),
              let cgr = dlsym(handle, "core_cmd_group_roster"),
              let ccdn = dlsym(handle, "core_cmd_cdn_urls"),
              let cgrp = dlsym(handle, "core_cmd_group_call_redeem_proof"),
              let cgim = dlsym(handle, "core_cmd_group_id_map"),
              let cgcpa = dlsym(handle, "core_cmd_group_call_proof_authorization"),
              let cgcid = dlsym(handle, "core_cmd_group_call_group_id"),
              let cgcmi = dlsym(handle, "core_cmd_group_call_member_identities"),
              let cgcsm = dlsym(handle, "core_cmd_group_call_set_membership_proof"),
              let cgcs = dlsym(handle, "core_cmd_group_call_set_group_members"),
              let cgcs2 = dlsym(handle, "core_cmd_group_call_start"),
              let cgcsj = dlsym(handle, "core_cmd_group_call_join"),
              let cgcsl = dlsym(handle, "core_cmd_group_call_leave"),
              let cgcse = dlsym(handle, "core_cmd_group_call_end"),
              let scs = dlsym(handle, "core_cmd_send_call_signal"),
              let bco = dlsym(handle, "core_cmd_build_call_offer"),
              let bca = dlsym(handle, "core_cmd_build_call_answer"),
              let bci = dlsym(handle, "core_cmd_build_call_ice"),
              let bch = dlsym(handle, "core_cmd_build_call_hangup"),
              let bcb = dlsym(handle, "core_cmd_build_call_busy"),
              let pcm = dlsym(handle, "core_cmd_parse_call_message"),
              let cers = dlsym(handle, "core_cmd_call_end_reason_to_string"),
              let dl = dlsym(handle, "core_cmd_delete_local"),
              let pf = dlsym(handle, "core_cmd_profile"),
              let w = dlsym(handle, "core_cmd_whoami"),
              let o = dlsym(handle, "core_cmd_logout"),
              let e = dlsym(handle, "core_last_error"),
              let f = dlsym(handle, "core_free_string") else { return nil }
        return Symbols(
            abiVersion: unsafeBitCast(abi, to: (@convention(c) () -> UInt32).self),
            initEncrypted: unsafeBitCast(i, to: (@convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int32).self),
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
            sendMessageEdit: unsafeBitCast(sme, to: (@convention(c) (UnsafePointer<CChar>, UInt64, UnsafePointer<CChar>) -> Int64).self),
            sendTyping: unsafeBitCast(sty, to: (@convention(c) (UnsafePointer<CChar>, Int32) -> Int32).self),
            sendCallOffer: unsafeBitCast(sco, to: (@convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int32).self),
            sendCallAnswer: unsafeBitCast(sca, to: (@convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int32).self),
            sendCallIce: unsafeBitCast(sci, to: (@convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafePointer<CChar>, UInt32) -> Int32).self),
            sendCallHangup: unsafeBitCast(sch, to: (@convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int32).self),
            callStart: unsafeBitCast(cst, to: (@convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> UInt64).self),
            callAccept: unsafeBitCast(cac, to: (@convention(c) (UInt64) -> Int32).self),
            callHangup: unsafeBitCast(cah, to: (@convention(c) () -> Int32).self),
            callSetMuted: unsafeBitCast(csm, to: (@convention(c) (Int32) -> Int32).self),
            httpResponse: unsafeBitCast(chr, to: (@convention(c) (UInt32, UInt32, UnsafePointer<UInt8>?, Int) -> Int32).self),
            groupAuthCredentials: unsafeBitCast(cgac, to: (@convention(c) () -> UnsafeMutablePointer<CChar>?).self),
            groupRoster: unsafeBitCast(cgr, to: (@convention(c) (UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?).self),
            cdnUrls: unsafeBitCast(ccdn, to: (@convention(c) () -> UnsafeMutablePointer<CChar>?).self),
            groupCallRedeemProof: unsafeBitCast(cgrp, to: (@convention(c) (UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?).self),
            groupIdMap: unsafeBitCast(cgim, to: (@convention(c) () -> UnsafeMutablePointer<CChar>?).self),
            groupCallProofAuthorization: unsafeBitCast(cgcpa, to: (@convention(c) (UnsafePointer<UInt8>?, UInt32) -> UnsafeMutablePointer<CChar>?).self),
            groupCallGroupId: unsafeBitCast(cgcid, to: (@convention(c) (UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?).self),
            groupCallMemberIdentities: unsafeBitCast(cgcmi, to: (@convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?).self),
            groupCallSetMembershipProof: unsafeBitCast(cgcsm, to: (@convention(c) (UInt32, UnsafePointer<UInt8>?, Int) -> Int32).self),
            groupCallSetGroupMembers: unsafeBitCast(cgcs, to: (@convention(c) (UInt32, UInt32, UnsafePointer<UInt8>?, UnsafePointer<UInt32>?, UnsafePointer<UInt8>?, UInt32) -> Int32).self),
            groupCallStart: unsafeBitCast(cgcs2, to: (@convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UInt64).self),
            groupCallJoin: unsafeBitCast(cgcsj, to: (@convention(c) (UInt32) -> Int32).self),
            groupCallLeave: unsafeBitCast(cgcsl, to: (@convention(c) (UInt32) -> Int32).self),
            groupCallEnd: unsafeBitCast(cgcse, to: (@convention(c) (UInt32) -> Int32).self),
            sendCallSignal: unsafeBitCast(scs, to: (@convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int32).self),
            buildCallOffer: unsafeBitCast(bco, to: (@convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?).self),
            buildCallAnswer: unsafeBitCast(bca, to: (@convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?).self),
            buildCallIce: unsafeBitCast(bci, to: (@convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?).self),
            buildCallHangup: unsafeBitCast(bch, to: (@convention(c) (UnsafePointer<CChar>, UInt32, UInt32) -> UnsafeMutablePointer<CChar>?).self),
            buildCallBusy: unsafeBitCast(bcb, to: (@convention(c) (UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?).self),
            parseCallMessage: unsafeBitCast(pcm, to: (@convention(c) (UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?).self),
            callEndReasonToString: unsafeBitCast(cers, to: (@convention(c) (Int32) -> UnsafeMutablePointer<CChar>?).self),
            deleteLocal: unsafeBitCast(dl, to: (@convention(c) (UnsafePointer<CChar>, UInt64) -> Int32).self),
            profile: unsafeBitCast(pf, to: (@convention(c) (UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?).self),
            whoami: unsafeBitCast(w, to: (@convention(c) () -> UnsafeMutablePointer<CChar>?).self),
            logout: unsafeBitCast(o, to: (@convention(c) () -> Int32).self),
            wipe: wp.map { unsafeBitCast($0, to: (@convention(c) () -> Int32).self) },
            lastError: unsafeBitCast(e, to: (@convention(c) () -> UnsafePointer<CChar>?).self),
            freeString: unsafeBitCast(f, to: (@convention(c) (UnsafeMutablePointer<CChar>?) -> Void).self)
        )
        #else
        return nil
        #endif
    }

    private static func validateLoadedLibrary(_ handle: UnsafeMutableRawPointer, at path: String) -> Bool {
        guard let symbols = resolve(in: handle) else { return false }
        guard symbols.abiVersion() == expectedNativeABI else {
            Log.error("native core ABI mismatch: expected \(expectedNativeABI), got \(symbols.abiVersion())")
            return false
        }
        #if !DEBUG
        guard isReleaseBundlePath(path) else {
            Log.error("native core rejected: path is outside the signed app bundle")
            return false
        }
        #endif
        return true
    }

    private static func preflightLibrary(at path: String) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return false }
        #if !DEBUG
        guard isReleaseBundlePath(url.path) else { return false }
        guard verifyCodeSignature(url) else { return false }
        if let expected = expectedDylibHash(), !matchesSHA256(expected, for: url) {
            return false
        }
        #endif
        return true
    }

    private static func isReleaseBundlePath(_ path: String) -> Bool {
        let bundle = URL(fileURLWithPath: Bundle.main.bundlePath).standardizedFileURL.path
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.path
        return candidate == bundle || candidate.hasPrefix(bundle + "/")
    }

    private static func expectedDylibHash() -> String? {
        let value = ProcessInfo.processInfo.environment["CUZTOM_SIGNAL_CORE_SHA256"]
            ?? (Bundle.main.object(forInfoDictionaryKey: dylibHashInfoKey) as? String)
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private static func matchesSHA256(_ expected: String, for url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return digest == expected
    }

    private static func verifyCodeSignature(_ url: URL) -> Bool {
        #if canImport(Security)
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode)
        guard createStatus == errSecSuccess, let staticCode else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        return SecStaticCodeCheckValidity(staticCode, flags, nil) == errSecSuccess
        #else
        return false
        #endif
    }

    private static func openLibrary(at path: String) -> UnsafeMutableRawPointer? {
        #if canImport(Darwin)
        guard preflightLibrary(at: path) else { return nil }
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

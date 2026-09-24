import Foundation

/// UI-agnostic chat coordinator. No SwiftUI/Combine here so it builds and
/// tests under Command Line Tools; `XcodeApp` adds a thin @Observable wrapper.
///
/// Flow: `link()` -> load conversations into `store` -> `select()` pages
/// messages -> `send()` via the `SignalService` and mirrors into `store`.
/// M1 swaps the injected service from `MockSignalService` to `RustCoreService`
/// with no changes to this class.
@MainActor
public final class ChatController {
    public private(set) var connection: ConnectionState = .unlinked
    public private(set) var conversations: [Conversation] = []
    public private(set) var selectedId: String?
    public private(set) var messages: [ChatMessage] = []
    public private(set) var linkQR: LinkQR?
    public private(set) var lastError: String?
    public private(set) var lastSyncNote: String?

    private let service: any SignalService
    private var store: MessageStore
    private var observerTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?

    public init(service: any SignalService, store: MessageStore = MessageStore()) {
        self.service = service
        self.store = store
    }

    public var isLinked: Bool {
        connection == .connected || connection == .syncing
    }

    public func link(deviceName: String = "CuztomMac") async {
        lastError = nil
        guard await begin(deviceName: deviceName) else { return }
        _ = await finish()
    }

    /// Step 1: fetch the provisioning QR. Returns false on error.
    /// An existing session (`alreadyLinked`) resumes without a QR.
    public func begin(deviceName: String = "CuztomMac") async -> Bool {
        lastError = nil
        do {
            linkQR = try await service.beginLinking(deviceName: deviceName)
            connection = .linking
            observeConnection()
            Log.info("provisioning QR ready")
            return true
        } catch SignalError.alreadyLinked {
            linkQR = nil
            connection = .syncing
            observeConnection()
            Log.info("resuming existing session (no QR)")
            return true
        } catch {
            lastError = String(describing: error)
            connection = .offline
            Log.error("begin failed: \(error)")
            return false
        }
    }

    /// Step 2: wait for the phone scan, then sync. Returns false on error.
    /// Split from `begin()` so UI can paint the QR while this runs.
    public func finish() async -> Bool {
        do {
            try await service.waitForLink()
            connection = .syncing
            // Live backend: pull contact sync + start the receive loop.
            // Non-fatal: the roster still loads from the local store.
            if let live = service as? RustCoreService {
                live.onSyncEvent = { [weak self] note in
                    Task { await self?.noteSync(note) }
                }
                do {
                    try await live.startLiveSync()
                    Log.info("live sync started")
                } catch {
                    lastError = String(describing: error)
                    Log.error("live sync failed: \(error)")
                }
            }
            try await refresh()
            connection = .connected
            startWatching()
            Log.info("linked: \(conversations.count) conversations")
            return true
        } catch {
            lastError = String(describing: error)
            connection = .offline
            Log.error("finish failed: \(error)")
            return false
        }
    }

    private func noteSync(_ note: String) {
        lastSyncNote = note
        Log.info("sync event: \(note)")
    }

    /// Stream live inbound messages into the store for the session lifetime.
    public func startWatching() {
        watchTask?.cancel()
        watchTask = Task { [weak self] in
            guard let stream = self?.service.incomingMessages() else { return }
            for await message in stream {
                await self?.receive(message)
            }
        }
    }

    public func refresh() async throws {
        let convs = try await service.fetchConversations()
        for c in convs {
            await store.upsertConversation(c)
            let history = try await service.fetchMessages(conversationId: c.id, limit: 200)
            for m in history { await store.saveMessage(m) }
        }
        conversations = await store.allConversations()
        if let id = selectedId {
            messages = await store.messages(in: id)
        }
        Log.info("refresh: \(conversations.count) conversations, \(await store.totalMessageCount()) messages")
    }

    /// Manual refresh that records (rather than throws) failures.
    @discardableResult
    public func refreshNow() async -> Bool {
        do {
            try await refresh()
            return true
        } catch {
            lastError = String(describing: error)
            Log.error("refresh failed: \(error)")
            return false
        }
    }

    /// Log out of Signal (wipes keys/session) and reset local state.
    /// Next `link()` shows a fresh QR.
    public func logout() async -> Bool {
        if let live = service as? RustCoreService {
            do {
                try await live.logout()
            } catch {
                lastError = String(describing: error)
                Log.error("logout failed: \(error)")
                return false
            }
        }
        observerTask?.cancel()
        watchTask?.cancel()
        store = MessageStore()
        conversations = []
        messages = []
        selectedId = nil
        linkQR = nil
        lastSyncNote = nil
        connection = .unlinked
        Log.info("logged out")
        return true
    }

    public func diagnostics() async -> String {
        let msgCount = await store.totalMessageCount()
        var lines = [
            "connection: \(connection.rawValue)",
            "conversations: \(conversations.count)",
            "messages: \(msgCount)",
            "selected: \(selectedId ?? "none")",
        ]
        if let live = service as? RustCoreService {
            lines.append("backend: live (\(live.libraryPath ?? "?"))")
            lines.append("roster: \(live.lastRosterSummary)")
            if let me = try? await live.whoami() {
                lines.append("account: \(me.number) (\(String(me.aci.prefix(8))))")
            }
        } else {
            lines.append("backend: mock")
        }
        lines.append("last sync: \(lastSyncNote ?? "none")")
        lines.append("last error: \(lastError ?? "none")")
        lines.append("log: \(Log.fileURL.path)")
        return lines.joined(separator: "\n")
    }

    public func select(_ id: String) async {
        selectedId = id
        // Top up from the service so threads opened after sync (or with
        // arrivals since sync) are complete; saveMessage dedupes by id.
        if let history = try? await service.fetchMessages(conversationId: id, limit: 200) {
            for m in history { await store.saveMessage(m) }
        }
        await store.markRead(conversationId: id)
        messages = await store.messages(in: id)
        if let idx = conversations.firstIndex(where: { $0.id == id }) {
            conversations[idx].unreadCount = 0
        }
    }

    public func send(_ body: String) async {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let id = selectedId else { return }
        do {
            let msg = try await service.sendText(trimmed, to: id)
            await store.saveMessage(msg)
            messages = await store.messages(in: id)
            Log.info("sent \(trimmed.count) chars to \(id)")
        } catch {
            lastError = String(describing: error)
            Log.error("send failed: \(error)")
        }
    }

    /// Append an inbound message (websocket callback target in M1).
    public func receive(_ message: ChatMessage) async {
        await store.saveMessage(message)
        conversations = await store.allConversations()
        if message.conversationId == selectedId {
            messages = await store.messages(in: message.conversationId)
        }
    }

    private func observeConnection() {
        observerTask?.cancel()
        observerTask = Task { [weak self] in
            guard let stream = self?.service.connectionState else { return }
            for await state in stream {
                await MainActor.run { [weak self] in
                    // Terminal .connected from waitForLink wins; only
                    // surface regressions (offline) from the backend.
                    if state == .offline { self?.connection = .offline }
                }
            }
        }
    }
}

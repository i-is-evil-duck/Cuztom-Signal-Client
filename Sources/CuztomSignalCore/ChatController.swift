import Foundation

/// UI-agnostic chat coordinator. No SwiftUI/Combine here so it builds and
/// tests under Command Line Tools; `XcodeApp` adds a thin @Observable wrapper.
///
/// Flow: `link()` -> load conversations into `store` -> `select()` pages
/// messages -> `send()` via the `SignalService` and mirrors into `store`.
/// M1 swaps the injected service from `MockSignalService` to `RustCoreService`
/// with no changes to this class.
@MainActor
public final class ChatController: @unchecked Sendable {
    public private(set) var connection: ConnectionState = .unlinked
    public private(set) var conversations: [Conversation] = []
    public private(set) var selectedId: String?
    public private(set) var messages: [ChatMessage] = []
    public private(set) var linkQR: LinkQR?
    public private(set) var lastError: String?
    public private(set) var lastSyncNote: String?
    /// Thread id of the most recent send (send-target tracing).
    public private(set) var lastSentThread: String?
    /// Own ACI for quoting/authoring (resolved at link time).
    public private(set) var selfAci: String?
    /// Monotonic selection token. Async history loads must not let an older
    /// conversation selection overwrite a newer one.
    private var selectionGeneration = 0

    private let service: any SignalService
    private var store: any MessageStoring
    private var observerTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?
    private let pluginHost: PluginHost
    private let contactResolver: ContactResolver

    public init(
        service: any SignalService,
        store: any MessageStoring = InMemoryMessageStore(),
        pluginHost: PluginHost = PluginHost()
    ) {
        self.service = service
        self.store = store
        self.pluginHost = pluginHost
        self.contactResolver = ContactResolver(rustCore: service as? RustCoreService)
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
                    Task { @MainActor in self?.noteSync(note) }
                }
                live.onReaction = { [weak self] thread, sts, emoji, remove, sender in
                    Task { await self?.applyReaction(thread: thread, targetSts: sts, emoji: emoji, remove: remove, senderName: sender) }
                }
                live.onReceipt = { [weak self] sender, kind, stamps in
                    Task { await self?.applyReceipt(kind: kind, timestamps: stamps, senderName: sender) }
                }
                live.onTyping = { [weak self] thread, sender, started in
                    Task { await self?.applyTyping(thread: thread, senderName: sender, started: started) }
                }
                do {
                    try await live.startLiveSync()
                    Log.info("live sync started")
                    if let me = try? await live.whoami() {
                        selfAci = me.aci
                        live.selfAci = me.aci
                    }
                } catch {
                    lastError = String(describing: error)
                    Log.error("live sync failed: \(error)")
                }
            }
            try await refresh()
            connection = .connected
            startWatching()
            Log.info("linked: \(conversations.count) conversations")
            // Backfill media caches quietly (roster rows are metadata-only).
            Task { await self.autoFetchMissing() }
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

        // `contacts_synced` is emitted after the Rust contact transaction has
        // been observed. It is the authoritative point to reload the roster;
        // `queue_empty` only means the websocket queue drained.
        guard note == "contacts_synced" else { return }
        rosterRefreshTask?.cancel()
        rosterRefreshTask = Task { [weak self] in
            guard let self, !Task.isCancelled, self.isLinked else { return }
            do {
                try await self.refresh()
                self.onRosterChanged?()
            } catch {
                Log.error("roster refresh after contacts sync failed: \(error)")
            }
        }
    }

    /// Apply a live reaction to the targeted message (matched by store ts).
    public func applyReaction(thread: String, targetSts: Int64, emoji: String, remove: Bool, senderName: String) async {
        let list = await store.messages(in: thread)
        guard let target = list.first(where: { ($0.storeTs ?? Int64($0.sentAt.timeIntervalSince1970 * 1000)) == targetSts }) else { return }
        await store.updateMessage(id: target.id) { msg in
            if remove {
                msg.reactions.removeAll { $0 == emoji }
            } else if !msg.reactions.contains(emoji) {
                msg.reactions.append(emoji)
            }
        }
        if thread == selectedId {
            messages = await store.messages(in: thread)
        }
        Log.info("reaction \(emoji) from \(senderName) in \(thread)")
    }

    /// Apply a read/delivery receipt to matching own messages.
    public func applyReceipt(kind: String, timestamps: [Int64], senderName: String) async {
        var touched: String?
        for (thread, list) in await allThreadLists() {
            for m in list where m.direction == .outgoing {
                let ms = Int64(m.sentAt.timeIntervalSince1970 * 1000)
                if timestamps.contains(ms) || (m.storeTs.map { timestamps.contains($0) } ?? false) {
                    await store.updateMessage(id: m.id) { msg in
                        if kind == "read" {
                            if !msg.readBy.contains(senderName) { msg.readBy.append(senderName) }
                        } else {
                            if !msg.deliveredTo.contains(senderName) { msg.deliveredTo.append(senderName) }
                        }
                    }
                    touched = thread
                }
            }
        }
        if let touched, touched == selectedId {
            messages = await store.messages(in: touched)
        }
    }

    /// Callback for typing indicator updates (set by ViewModel for UI).
    public var onTypingUpdate: ((String, String, Bool) -> Void)?
    /// Called after an inbound chat message is accepted by the store.
    public var onIncomingMessage: ((ChatMessage) -> Void)?
    /// Called after a contacts/groups sync refreshes the roster.
    public var onRosterChanged: (() -> Void)?

    private var rosterRefreshTask: Task<Void, Never>?

    /// Resolve a display name for an ACI/UUID in a conversation.
    public func displayName(for aci: String, in conversationId: String) async -> String {
        await contactResolver.displayName(for: aci, in: conversationId, conversations: conversations)
    }

    /// Apply a live typing indicator to the conversation.
    public func applyTyping(thread: String, senderName: String, started: Bool) async {
        Log.info("typing \(started ? "started" : "stopped") by \(senderName) in \(thread)")
        onTypingUpdate?(thread, senderName, started)
    }


    /// Outgoing typing is currently disabled. The presage sender persists
    /// TypingMessage as a normal content message and the Signal service
    /// rejects that path; firing it on every keystroke also delays real sends.
    /// Incoming typing updates remain fully supported.
    public func sendTyping(thread: String, started: Bool) async {
        _ = thread
        _ = started
    }

    private func allThreadLists() async -> [(String, [ChatMessage])] {
        var out: [(String, [ChatMessage])] = []
        for c in conversations {
            out.append((c.id, await store.messages(in: c.id)))
        }
        return out
    }

    /// Toggle/add an emoji reaction on a message.
    public func react(messageId: UUID, emoji: String) async -> Bool {
        guard let live = service as? RustCoreService,
              let stored = await store.message(id: messageId) else { return false }
        let author = stored.direction == .outgoing ? (selfAci ?? stored.author.uuidString ?? "") : (stored.author.uuidString ?? "")
        let sts = stored.storeTs ?? Int64(stored.sentAt.timeIntervalSince1970 * 1000)
        let remove = stored.reactions.contains(emoji)
        do {
            try await live.sendReaction(thread: stored.conversationId, targetSts: sts, author: author, emoji: emoji, remove: remove)
            await store.updateMessage(id: messageId) { msg in
                if remove {
                    msg.reactions.removeAll { $0 == emoji }
                } else if !msg.reactions.contains(emoji) {
                    msg.reactions.append(emoji)
                }
            }
            if stored.conversationId == selectedId {
                messages = await store.messages(in: stored.conversationId)
            }
            return true
        } catch {
            lastError = String(describing: error)
            Log.error("react failed: \(error)")
            return false
        }
    }

    /// Delete a message. `forEveryone` sends a remote tombstone first (own
    /// messages only); local removal always also clears the Rust store row
    /// so refreshes never resurrect it.
    public func deleteMessage(id: UUID, forEveryone: Bool) async -> Bool {
        guard let stored = await store.message(id: id) else { return false }
        let sts = stored.storeTs ?? Int64(stored.sentAt.timeIntervalSince1970 * 1000)
        if forEveryone {
            guard stored.direction == .outgoing, let live = service as? RustCoreService else { return false }
            do {
                try await live.sendDeleteTombstone(thread: stored.conversationId, targetTs: sts)
            } catch {
                lastError = String(describing: error)
                Log.error("remote delete failed: \(error)")
                return false
            }
        }
        if let live = service as? RustCoreService {
            _ = try? await live.deleteLocal(thread: stored.conversationId, sts: sts)
        }
        _ = await store.deleteMessage(id: id)
        if stored.conversationId == selectedId {
            messages = await store.messages(in: stored.conversationId)
        }
        conversations = await store.allConversations()
        Log.info("deleted \(id) everyone=\(forEveryone)")
        return true
    }

    /// Upload + send a local file (`caption` = message body, may be empty).
    public func sendAttachment(
        fileURL: URL,
        caption: String,
        to requestedID: String? = nil
    ) async -> Bool {
        lastError = nil
        Log.info("attachment send start: \(fileURL.lastPathComponent) caption=\(caption.count) chars")
        guard let id = requestedID ?? selectedId else {
            lastError = "no conversation selected"
            Log.error("attachment send: no conversation selected")
            return false
        }
        guard let live = service as? RustCoreService else {
            lastError = "attachments need the live backend"
            Log.error("attachment send: no live backend")
            return false
        }
        do {
            let sent = try await live.sendAttachment(thread: id, path: fileURL.path, caption: caption)

            // Copy sent attachment to permanent cache and register path for rendering
            let cacheURL = live.cacheSentAttachment(thread: id, ts: sent.ts, sourceURL: fileURL, filename: sent.name)
            let meta = AttachmentMeta(filename: sent.name, mimeType: sent.mime, byteCount: sent.size, localURL: cacheURL)

            let msg = ChatMessage(
                conversationId: id,
                author: SignalAddress(uuidString: selfAci ?? "self", threadId: id),
                body: caption,
                direction: .outgoing,
                status: .sent,
                attachments: [meta],
                storeTs: sent.ts
            )
            lastSentThread = id
            await store.saveMessage(msg)
            if selectedId == id {
                messages = await store.messages(in: id)
            }
            conversations = await store.allConversations()
            Log.info("sent attachment \(sent.name) to \(id)")
            return true
        } catch {
            lastError = String(describing: error)
            Log.error("attachment send failed: \(error)")
            return false
        }
    }

    /// Reply quoting another message.
    public func sendReply(body: String, to id: String, quote: ChatMessage) async {
        lastError = nil
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let live = service as? RustCoreService else {
            await send(body)
            return
        }
        let qTs = quote.storeTs ?? Int64(quote.sentAt.timeIntervalSince1970 * 1000)
        let qAuthor = quote.direction == .outgoing ? (selfAci ?? "") : (quote.author.uuidString ?? "")
        do {
            let ts = try await live.sendReply(thread: id, body: trimmed, qTs: qTs, qAuthor: qAuthor, qBody: String(quote.body.prefix(200)))
            let msg = ChatMessage(
                conversationId: id,
                author: SignalAddress(uuidString: selfAci ?? "self", threadId: id),
                body: trimmed,
                direction: .outgoing,
                status: .sent,
                sentAt: Date(timeIntervalSince1970: Double(ts) / 1000),
                storeTs: ts
            )
            lastSentThread = id
            await store.saveMessage(msg)
            messages = await store.messages(in: id)
            conversations = await store.allConversations()
            Log.info("sent reply to \(id)")
        } catch {
            lastError = String(describing: error)
            Log.error("reply failed: \(error)")
        }
    }

    /// Edit an outgoing message (replaces content). Returns sent timestamp.
    public func sendMessageEdit(thread: String, targetTs: Int64, newBody: String) async -> Int64 {
        guard let live = service as? RustCoreService else {
            lastError = "message edits need the live backend"
            Log.error("message edit: no live backend")
            return -1
        }
        do {
            let ts = try await live.sendMessageEdit(thread: thread, targetTs: targetTs, newBody: newBody)
            // Update local message store
            // Find the message by storeTs and update its body
            let messagesInThread = await store.messages(in: thread)
            if let idx = messagesInThread.firstIndex(where: { $0.storeTs == targetTs }) {
                await store.updateMessage(id: messagesInThread[idx].id) { m in
                    m.body = newBody
                }
            }
            if thread == selectedId {
                messages = await store.messages(in: thread)
            }
            conversations = await store.allConversations()
            Log.info("edited message in \(thread)")
            return ts
        } catch {
            lastError = String(describing: error)
            Log.error("message edit failed: \(error)")
            return -1
        }
    }

    /// Fill in profile display names for contacts whose synced row is blank
    /// (typically added by phone number). Keeps existing titles otherwise.
    public func enrichNames() async {
        guard let live = service as? RustCoreService else { return }
        for conv in conversations where !conv.peer.isGroup {
            let looksBare = conv.title == "Unknown"
                || conv.title.isEmpty
                || conv.title.count == 8
                || conv.title.hasPrefix("+")
                || conv.title == conv.peer.uuidString
            guard looksBare, let uuid = conv.peer.uuidString else { continue }
            if let selfAci, uuid.caseInsensitiveCompare(selfAci) == .orderedSame {
                continue
            }
            if let name = await live.profileName(uuid: uuid), !name.isEmpty {
                await store.renameConversation(id: conv.id, title: name)
                Log.info("resolved name for \(uuid): \(name)")
            }
        }
        conversations = await store.allConversations()
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
        await enrichNames()

        // Populate contact resolver from roster if using live backend
        if let live = service as? RustCoreService,
           let rosterData = try? await live.getRosterData() {
            await contactResolver.populateFromRoster(rosterData.contacts)
            await contactResolver.populateFromGroups(rosterData.groups)
        }

        conversations = await store.allConversations()
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

    /// Ask the phone to re-send contacts/groups (live backend only).
    public func requestSync() async -> Bool {
        guard let live = service as? RustCoreService else { return false }
        do {
            try await live.requestContactSync()
            Log.info("contact sync requested")
            return true
        } catch {
            lastError = String(describing: error)
            Log.error("contact sync failed: \(error)")
            return false
        }
    }

    /// Reset Swift-side state after the live service has already performed its
    /// logout/data wipe. This avoids issuing a second FFI logout, which is
    /// expected to return `not linked` after the first successful wipe.
    public func resetAfterServiceLogout() async {
        observerTask?.cancel()
        watchTask?.cancel()
        rosterRefreshTask?.cancel()
        rosterRefreshTask = nil
        // The Rust Signal database and the Swift presentation database are
        // separate stores. Clear both so a relink cannot resurrect the prior
        // account's conversations, unread counts, or message UUIDs.
        await store.clearAllData()
        store = MessageStore()
        conversations = []
        messages = []
        selectedId = nil
        linkQR = nil
        lastSyncNote = nil
        lastError = nil
        connection = .unlinked
        Log.info("local controller state reset after service logout")
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
        await resetAfterServiceLogout()
        Log.info("logged out")
        return true
    }

    /// Clear all local data (messages, conversations) without logging out from Signal.
    /// Used as part of full logout flow.
    public func clearAllData() async {
        await store.clearAllData()
        conversations = []
        messages = []
        selectedId = nil
        Log.info("ChatController: cleared all local data")
    }

    /// Send delivery receipts for incoming messages.
    public func sendDeliveryReceipts(for conversationId: String, timestamps: [Int64]) async throws {
        guard let live = service as? RustCoreService else {
            throw SignalError.unsupported("delivery receipts need the live backend")
        }
        if !timestamps.isEmpty {
            try await live.sendReceipt(thread: conversationId, timestamps: timestamps, kind: "delivered")
        }
    }

    /// Send read receipts for all unread messages in a conversation.
    public func sendReadReceipts(for conversationId: String) async throws {
        guard let live = service as? RustCoreService else {
            throw SignalError.unsupported("read receipts need the live backend")
        }
        // Get unread messages in this conversation
        let messages = await store.messages(in: conversationId)
        let unreadMessages = messages.filter {
            $0.direction == .incoming && !$0.readBy.contains(selfAci ?? "")
        }
        // Extract timestamps
        let timestamps = unreadMessages.compactMap { $0.storeTs }
        if !timestamps.isEmpty {
            try await live.sendReceipt(thread: conversationId, timestamps: timestamps, kind: "read")
        }
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
        lines.append("last sent to: \(lastSentThread ?? "none")")
        lines.append("last error: \(lastError ?? "none")")
        lines.append("log: \(Log.fileURL.path)")
        return lines.joined(separator: "\n")
    }

    public func select(_ id: String) async {
        selectionGeneration += 1
        let generation = selectionGeneration
        selectedId = id
        // Top up from the service so threads opened after sync (or with
        // arrivals since sync) are complete; saveMessage dedupes by id.
        if let history = try? await service.fetchMessages(conversationId: id, limit: 200) {
            for m in history { await store.saveMessage(m) }
        }
        guard generation == selectionGeneration else { return }
        await store.markRead(conversationId: id)
        guard generation == selectionGeneration else { return }
        messages = await store.messages(in: id)
        guard generation == selectionGeneration else { return }
        if let idx = conversations.firstIndex(where: { $0.id == id }) {
            conversations[idx].unreadCount = 0
        }

        // Auto-send read receipts for unread messages in this conversation
        guard generation == selectionGeneration else { return }
        do {
            try await sendReadReceipts(for: id)
        } catch {
            Log.error("failed to send read receipts: \(error)")
        }
    }

    public func send(_ body: String, to requestedID: String? = nil) async {
        lastError = nil
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let id = requestedID ?? selectedId else { return }
        do {
            let msg = try await service.sendText(trimmed, to: id)
            lastSentThread = id
            await store.saveMessage(msg)
            if selectedId == id {
                messages = await store.messages(in: id)
            }
            conversations = await store.allConversations()
            Log.info("sent \(trimmed.count) chars to \(id)")
        } catch {
            lastError = String(describing: error)
            Log.error("send failed: \(error)")
        }
    }

    /// Send text, or run a `/command` through `plugins` (reply is ephemeral).
    public func sendOrCommand(_ body: String, plugins: PluginHost, ctx: PluginContext) async {
        if body.hasPrefix("/") {
            switch await plugins.handleInput(body, ctx: ctx) {
            case .sendOriginal:
                break
            case .reply(let text):
                await injectEphemeral(text)
                return
            case .silent:
                return
            }
        }
        await send(body)
    }

    /// Grow the open thread by one more history page (see `fetchMessages`).
    /// Returns true when new rows arrived; false means exhausted (or failed).
    @discardableResult
    public func loadMore(chunk: Int = 100) async -> Bool {
        guard let id = selectedId else { return false }
        let current = await store.messageCount(in: id)
        do {
            let merged = try await service.fetchMessages(conversationId: id, limit: current + chunk)
            for m in merged { await store.saveMessage(m) }
            messages = await store.messages(in: id)
            let grew = messages.count > current
            Log.info("loadMore \(id): \(current) -> \(messages.count)")
            return grew
        } catch {
            lastError = String(describing: error)
            Log.error("loadMore failed: \(error)")
            return false
        }
    }

    public func messages(in id: String, limit: Int = 200) async -> [ChatMessage] {
        await store.messages(in: id, limit: limit)
    }

    /// On-demand attachment download for metadata-only rows.
    @discardableResult
    public func downloadAttachment(messageId: UUID, index: Int) async -> Bool {
        guard let live = service as? RustCoreService,
              let stored = await store.message(id: messageId),
              stored.attachments.indices.contains(index) else { return false }
        // Store-clock timestamp is the lookup key; fall back to display ts.
        let sts = stored.storeTs ?? Int64(stored.sentAt.timeIntervalSince1970 * 1000)
        do {
            let url = try await live.fetchAttachment(
                thread: stored.conversationId,
                ts: sts,
                index: index
            )
            live.bindLocalPath(thread: stored.conversationId, ts: sts, index: index, path: url.path)
            await store.updateMessage(id: messageId) { $0.attachments[index].localURL = url }
            if stored.conversationId == selectedId {
                messages = await store.messages(in: stored.conversationId)
            }
            Log.info("attachment saved: \(url.lastPathComponent)")
            return true
        } catch {
            lastError = String(describing: error)
            Log.error("attachment fetch failed: \(error)")
            return false
        }
    }

    /// Append an inbound message (websocket callback target in M1).
    public func receive(_ message: ChatMessage) async {
        // Reactions/control envelopes are delivered separately by the native
        // core. A legacy empty payload must never become a blank chat bubble.
        if message.direction == .incoming,
           message.body.isEmpty,
           message.attachments.isEmpty {
            return
        }
        let inserted = await store.saveMessage(message)
        if inserted && message.direction == .incoming {
            onIncomingMessage?(message)
        }
        conversations = await store.allConversations()
        if message.conversationId == selectedId {
            messages = await store.messages(in: message.conversationId)
        }

        // Auto-send delivery receipt for incoming messages
        if message.direction == .incoming, let sts = message.storeTs {
            do {
                try await sendDeliveryReceipts(for: message.conversationId, timestamps: [sts])
            } catch {
                Log.error("failed to send delivery receipt: \(error)")
            }
        }

        // Fan out to plugins (onMessage hooks) — capture actor-isolated values here
        let currentConversations = conversations
        let currentSelectedId = selectedId
        let currentSelfAci = selfAci
        let ctx = PluginContext(
            conversations: { currentConversations },
            selectedThread: { currentSelectedId },
            recentMessages: { id, limit in await self.store.messages(in: id, limit: limit) },
            diagnostics: { await self.diagnostics() },
            account: { currentSelfAci ?? "unknown" },
            rosterSummary: { "\(currentConversations.count) conversations" },
            requestSync: { await self.requestSync() }
        )
        await pluginHost.notifyMessage(message, ctx: ctx)
    }

    /// Auto-fetch missing attachments after launch (roster seeds metadata
    /// only). Media (images/video, incl. GIFs) fetch automatically; other
    /// file types stay manual. Bounded: newest-first, capped count.
    /// Fire-and-forget from `finish()`; failures stay quiet in the log.
    public func autoFetchMissing(maxFiles: Int = 20) async {
        guard service is RustCoreService else { return }
        var fetched = 0
        for conv in conversations {
            if fetched >= maxFiles { break }
            let list = await store.messages(in: conv.id)
            for m in list.reversed() {
                if fetched >= maxFiles { break }
                for idx in m.attachments.indices {
                    let att = m.attachments[idx]
                    if let localURL = att.localURL,
                       !FileManager.default.fileExists(atPath: localURL.path) {
                        await store.updateMessage(id: m.id) { message in
                            message.attachments[idx].localURL = nil
                        }
                    }
                    let stillHasFile = att.localURL.map {
                        FileManager.default.fileExists(atPath: $0.path)
                    } ?? false
                    guard !stillHasFile, att.isImage || att.isVideo else { continue }
                    if await downloadAttachment(messageId: m.id, index: idx) {
                        fetched += 1
                    }
                }
            }
        }
        if fetched > 0 {
            messages = await store.messages(in: selectedId ?? "")
            Log.info("auto-fetch: \(fetched) attachments")
        }
    }

    /// Ephemeral local message (plugin replies). Shown in the open thread
    /// only — never persisted, never sent.
    public func injectEphemeral(_ body: String, threadId: String? = nil) async {
        let target = threadId ?? selectedId
        guard let target else { return }
        let msg = ChatMessage(
            conversationId: target,
            author: SignalAddress(uuidString: "plugin"),
            body: body,
            direction: .incoming,
            status: .read,
            sentAt: Date()
        )
        if target == selectedId {
            messages.append(msg)
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

import Foundation

public enum LoadMoreResult: Sendable {
    case loaded
    case exhausted
    case failed(String)
    case cancelled
}

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
    /// Monotonic lifecycle token. Results from a previous account/session
    /// must not publish state after logout or relink.
    private var lifecycleGeneration = 0

    private let service: any SignalService
    private var store: any MessageStoring
    private var observerTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?
    private var autoFetchTask: Task<Void, Never>?
    private var liveFetchTasks: [UUID: Task<Void, Never>] = [:]
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
            notifyStateChange()
            observeConnection()
            Log.info("provisioning QR ready")
            return true
        } catch SignalError.alreadyLinked {
            linkQR = nil
            connection = .syncing
            notifyStateChange()
            observeConnection()
            Log.info("resuming existing session (no QR)")
            return true
        } catch {
            lastError = String(describing: error)
            connection = .offline
            notifyStateChange()
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
            notifyStateChange()
            // Live backend: pull contact sync + start the receive loop.
            // Non-fatal: the roster still loads from the local store.
            if let live = service as? RustCoreService {
                let callbackLifecycle = lifecycleGeneration
                live.onSyncEvent = { [weak self] note in
                    Task { @MainActor [weak self] in
                        guard let self, self.lifecycleGeneration == callbackLifecycle else { return }
                        self.noteSync(note)
                    }
                }
                live.onReaction = { [weak self] thread, sts, emoji, remove, sender in
                    Task { @MainActor [weak self] in
                        guard let self, self.lifecycleGeneration == callbackLifecycle else { return }
                        await self.applyReaction(thread: thread, targetSts: sts, emoji: emoji, remove: remove, senderName: sender)
                    }
                }
                live.onReceipt = { [weak self] sender, kind, stamps in
                    Task { @MainActor [weak self] in
                        guard let self, self.lifecycleGeneration == callbackLifecycle else { return }
                        await self.applyReceipt(kind: kind, timestamps: stamps, senderID: sender)
                    }
                }
                live.onReceiptScoped = { [weak self] thread, sender, kind, stamps in
                    Task { @MainActor [weak self] in
                        guard let self, self.lifecycleGeneration == callbackLifecycle else { return }
                        await self.applyReceipt(
                            kind: kind,
                            timestamps: stamps,
                            thread: thread,
                            senderID: sender
                        )
                    }
                }
                live.onTyping = { [weak self] thread, sender, started in
                    Task { @MainActor [weak self] in
                        guard let self, self.lifecycleGeneration == callbackLifecycle else { return }
                        await self.applyTyping(thread: thread, senderName: sender, started: started)
                    }
                }
                live.onTypingWithID = { [weak self] thread, senderID, senderName, started in
                    Task { @MainActor [weak self] in
                        guard let self, self.lifecycleGeneration == callbackLifecycle else { return }
                        await self.applyTyping(
                            thread: thread,
                            senderName: senderName,
                            started: started,
                            senderID: senderID
                        )
                    }
                }
                live.onEdit = { [weak self] thread, sts, body, sender, senderName in
                    Task { @MainActor [weak self] in
                        guard let self, self.lifecycleGeneration == callbackLifecycle else { return }
                        await self.applyEdit(thread: thread, targetSts: sts, body: body, senderID: sender, senderName: senderName)
                    }
                }
                live.onDelete = { [weak self] thread, sts, sender, senderName in
                    Task { @MainActor [weak self] in
                        guard let self, self.lifecycleGeneration == callbackLifecycle else { return }
                        await self.applyDelete(thread: thread, targetSts: sts, senderID: sender, senderName: senderName)
                    }
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
            notifyStateChange()
            startWatching()
            Log.info("linked: \(conversations.count) conversations")
            // Backfill media caches quietly (roster rows are metadata-only).
            autoFetchTask?.cancel()
            autoFetchTask = Task { [weak self] in
                await self?.autoFetchMissing()
            }
            return true
        } catch {
            lastError = String(describing: error)
            connection = .offline
            notifyStateChange()
            Log.error("finish failed: \(error)")
            return false
        }
    }

    private func noteSync(_ note: String) {
        lastSyncNote = note
        Log.info("sync event: \(note)")
        notifyStateChange()

        // `contacts_synced` is emitted after the Rust contact transaction has
        // been observed. It is the authoritative point to reload the roster;
        // `queue_empty` only means the websocket queue drained.
        guard note == "contacts_synced" else { return }
        rosterRefreshTask?.cancel()
        let lifecycle = lifecycleGeneration
        rosterRefreshTask = Task { @MainActor [weak self] in
            guard let self,
                  !Task.isCancelled,
                  self.lifecycleGeneration == lifecycle,
                  self.isLinked else { return }
            do {
                try await self.refresh()
                guard self.lifecycleGeneration == lifecycle else { return }
                self.onRosterChanged?()
            } catch {
                Log.error("roster refresh after contacts sync failed: \(error)")
            }
        }
    }

    /// Apply a live reaction to the targeted message (matched by store ts).
    public func applyReaction(thread: String, targetSts: Int64, emoji: String, remove: Bool, senderName: String) async {
        let target = await store.message(conversationId: thread, storeTs: targetSts)
        guard let target else { return }
        await store.updateMessage(id: target.id) { msg in
            if remove {
                msg.reactions.removeAll { $0 == emoji }
            } else if !msg.reactions.contains(emoji) {
                msg.reactions.append(emoji)
            }
        }
        await reloadVisibleMessages(for: thread)
        notifyStateChange()
        Log.info("reaction \(emoji) from \(senderName) in \(thread)")
    }

    /// Apply a native edit event to the exact message identity. A name is
    /// presentation data; the stable sender ID is used for authorization.
    public func applyEdit(
        thread: String,
        targetSts: Int64,
        body: String,
        senderID: String,
        senderName: String
    ) async {
        guard let target = await store.message(conversationId: thread, storeTs: targetSts),
              eventAuthorMatches(target, senderID: senderID, senderName: senderName) else {
            return
        }
        await store.updateMessage(id: target.id) { message in
            message.body = body
        }
        await reloadVisibleMessages(for: thread)
        conversations = await store.allConversations()
        notifyStateChange()
        Log.info("edited \(targetSts) in \(thread) by \(senderName)")
    }

    /// Apply a native delete-for-everyone event to the exact message identity.
    public func applyDelete(
        thread: String,
        targetSts: Int64,
        senderID: String,
        senderName: String
    ) async {
        guard let target = await store.message(conversationId: thread, storeTs: targetSts),
              eventAuthorMatches(target, senderID: senderID, senderName: senderName) else {
            return
        }
        if let live = service as? RustCoreService {
            _ = try? await live.deleteLocal(thread: thread, sts: targetSts)
        }
        _ = await store.deleteMessage(conversationId: thread, storeTs: targetSts)
        await reloadVisibleMessages(for: thread)
        conversations = await store.allConversations()
        notifyStateChange()
        Log.info("deleted \(targetSts) in \(thread) by \(senderName)")
    }

    private func eventAuthorMatches(_ message: ChatMessage, senderID: String, senderName: String) -> Bool {
        // Some older native envelopes do not carry a stable sender. Preserve
        // compatibility for those events, but never accept a known mismatched
        // ACI/PNI identity.
        if senderID.isEmpty || senderID == "?" { return true }
        let author = message.author.uuidString ?? ""
        if author == senderID { return true }
        if message.direction == .outgoing,
           (author == "self" || senderID == (selfAci ?? "")) {
            return true
        }
        // Display names are only a fallback for legacy stores with no author
        // ID. Never use a name when both sides have stable IDs.
        if author.isEmpty && !senderName.isEmpty && senderName != "?" {
            return true
        }
        return false
    }

    /// Apply a read/delivery receipt to matching own messages. When the
    /// native event carries a direct-contact thread, scope the lookup to it.
    public func applyReceipt(
        kind: String,
        timestamps: [Int64],
        senderName: String? = nil,
        thread: String? = nil,
        senderID: String? = nil
    ) async {
        var touched: String?
        let participantID = senderID ?? senderName ?? "?"
        let lists: [(String, [ChatMessage])]
        if let thread {
            lists = [(thread, await store.messages(in: thread, limit: Int.max))]
        } else {
            lists = await allThreadLists()
        }
        for (thread, list) in lists {
            for m in list where m.direction == .outgoing {
                let ms = Int64(m.sentAt.timeIntervalSince1970 * 1000)
                if timestamps.contains(ms) || (m.storeTs.map { timestamps.contains($0) } ?? false) {
                    await store.updateMessage(id: m.id) { msg in
                        if kind == "read" {
                            if !msg.readBy.contains(participantID) { msg.readBy.append(participantID) }
                        } else {
                            if !msg.deliveredTo.contains(participantID) { msg.deliveredTo.append(participantID) }
                        }
                    }
                    touched = thread
                }
            }
        }
        if let touched {
            await reloadVisibleMessages(for: touched)
        }
        if touched != nil {
            notifyStateChange()
        }
    }

    /// Callback for typing indicator updates (set by ViewModel for UI).
    public var onTypingUpdate: ((String, String, Bool) -> Void)?
    /// Stable-ID typing callback for group conversations.
    public var onTypingUpdateWithID: ((String, String, String, Bool) -> Void)?
    /// Called after an inbound chat message is accepted by the store.
    public var onIncomingMessage: ((ChatMessage) -> Void)?
    /// Called after any controller-owned presentation state changes. The UI
    /// should use this instead of relying on unrelated refresh/send actions.
    public var onStateChange: (() -> Void)?
    /// Called after a contacts/groups sync refreshes the roster.
    public var onRosterChanged: (() -> Void)?

    private var rosterRefreshTask: Task<Void, Never>?

    /// Resolve a display name for an ACI/UUID in a conversation.
    public func displayName(for aci: String, in conversationId: String) async -> String {
        await contactResolver.displayName(for: aci, in: conversationId, conversations: conversations)
    }

    /// Apply a live typing indicator to the conversation.
    public func applyTyping(
        thread: String,
        senderName: String,
        started: Bool,
        senderID: String? = nil
    ) async {
        Log.info("typing \(started ? "started" : "stopped") by \(senderName) in \(thread)")
        if let senderID {
            onTypingUpdateWithID?(thread, senderID, senderName, started)
        } else {
            onTypingUpdate?(thread, senderName, started)
        }
    }


    /// Outgoing typing is currently disabled. The presage sender persists
    /// TypingMessage as a normal content message and the Signal service
    /// rejects that path; firing it on every keystroke also delays real sends.
    /// Incoming typing updates remain fully supported.
    public func sendTyping(thread: String, started: Bool) async {
        _ = thread
        _ = started
    }

    private func reloadVisibleMessages(for conversationId: String) async {
        guard selectedId == conversationId else { return }
        let limit = max(200, messages.count)
        messages = await store.messages(in: conversationId, limit: limit)
    }

    private func allThreadLists() async -> [(String, [ChatMessage])] {
        var out: [(String, [ChatMessage])] = []
        for c in conversations {
            out.append((c.id, await store.messages(in: c.id, limit: Int.max)))
        }
        return out
    }

    /// Toggle/add an emoji reaction on a message.
    public func react(messageId: UUID, emoji: String) async -> Bool {
        lastError = nil
        let lifecycle = lifecycleGeneration
        guard let live = service as? RustCoreService,
              let stored = await store.message(id: messageId) else { return false }
        let author = stored.direction == .outgoing ? (selfAci ?? stored.author.uuidString ?? "") : (stored.author.uuidString ?? "")
        let sts = stored.storeTs ?? Int64(stored.sentAt.timeIntervalSince1970 * 1000)
        let remove = stored.reactions.contains(emoji)
        do {
            try await live.sendReaction(thread: stored.conversationId, targetSts: sts, author: author, emoji: emoji, remove: remove)
            guard lifecycle == lifecycleGeneration else { return false }
            await store.updateMessage(id: messageId) { msg in
                if remove {
                    msg.reactions.removeAll { $0 == emoji }
                } else if !msg.reactions.contains(emoji) {
                    msg.reactions.append(emoji)
                }
            }
            await reloadVisibleMessages(for: stored.conversationId)
            notifyStateChange()
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
        let lifecycle = lifecycleGeneration
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
        guard lifecycle == lifecycleGeneration else { return false }
        _ = await store.deleteMessage(id: id)
        guard lifecycle == lifecycleGeneration else { return false }
        await reloadVisibleMessages(for: stored.conversationId)
        conversations = await store.allConversations()
        notifyStateChange()
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
        let lifecycle = lifecycleGeneration
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
            guard lifecycle == lifecycleGeneration else { return false }

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
            guard lifecycle == lifecycleGeneration else { return false }
            await store.saveMessage(msg)
            guard lifecycle == lifecycleGeneration else { return false }
            await reloadVisibleMessages(for: id)
            conversations = await store.allConversations()
            notifyStateChange()
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
        let lifecycle = lifecycleGeneration
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let live = service as? RustCoreService else {
            await send(body, to: id)
            return
        }
        let qTs = quote.storeTs ?? Int64(quote.sentAt.timeIntervalSince1970 * 1000)
        let qAuthor = quote.direction == .outgoing ? (selfAci ?? "") : (quote.author.uuidString ?? "")
        do {
            let ts = try await live.sendReply(thread: id, body: trimmed, qTs: qTs, qAuthor: qAuthor, qBody: String(quote.body.prefix(200)))
            guard lifecycle == lifecycleGeneration else { return }
            let msg = ChatMessage(
                conversationId: id,
                author: SignalAddress(uuidString: selfAci ?? "self", threadId: id),
                body: trimmed,
                direction: .outgoing,
                status: .sent,
                sentAt: Date(timeIntervalSince1970: Double(ts) / 1000),
                replyTo: MessageReference(
                    storeTs: qTs,
                    authorID: qAuthor.isEmpty ? nil : qAuthor,
                    body: String(quote.body.prefix(200))
                ),
                storeTs: ts
            )
            lastSentThread = id
            guard lifecycle == lifecycleGeneration else { return }
            await store.saveMessage(msg, countsAsUnread: false)
            guard lifecycle == lifecycleGeneration else { return }
            await reloadVisibleMessages(for: id)
            conversations = await store.allConversations()
            notifyStateChange()
            Log.info("sent reply to \(id)")
        } catch {
            lastError = String(describing: error)
            Log.error("reply failed: \(error)")
        }
    }

    /// Edit an outgoing message (replaces content). Returns sent timestamp.
    public func sendMessageEdit(thread: String, targetTs: Int64, newBody: String) async -> Int64 {
        let lifecycle = lifecycleGeneration
        guard let live = service as? RustCoreService else {
            lastError = "message edits need the live backend"
            Log.error("message edit: no live backend")
            return -1
        }
        do {
            let ts = try await live.sendMessageEdit(thread: thread, targetTs: targetTs, newBody: newBody)
            guard lifecycle == lifecycleGeneration else { return -1 }
            // Update the exact target, including targets older than the UI page.
            if let target = await store.message(conversationId: thread, storeTs: targetTs) {
                await store.updateMessage(id: target.id) { m in
                    m.body = newBody
                }
            }
            await reloadVisibleMessages(for: thread)
            conversations = await store.allConversations()
            notifyStateChange()
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
        let lifecycle = lifecycleGeneration
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
                guard lifecycle == lifecycleGeneration else { return }
                await store.renameConversation(id: conv.id, title: name)
                Log.info("resolved name for \(uuid): \(name)")
            }
        }
        guard lifecycle == lifecycleGeneration else { return }
        conversations = await store.allConversations()
    }

    /// Stream live inbound messages into the store for the session lifetime.
    public func startWatching() {
        watchTask?.cancel()
        let lifecycle = lifecycleGeneration
        watchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let stream = self.service.incomingMessages()
            for await message in stream {
                guard !Task.isCancelled, self.lifecycleGeneration == lifecycle else { return }
                await self.receive(message)
            }
        }
    }

    public func refresh() async throws {
        let lifecycle = lifecycleGeneration
        let convs = try await service.fetchConversations()
        guard lifecycle == lifecycleGeneration else { return }
        for c in convs {
            guard lifecycle == lifecycleGeneration else { return }
            await store.upsertConversation(c)
            guard lifecycle == lifecycleGeneration else { return }
            let history = try await service.fetchMessages(conversationId: c.id, limit: 200)
            guard lifecycle == lifecycleGeneration else { return }
            // Roster/history is a snapshot, not a live unread arrival.
            for m in history {
                guard lifecycle == lifecycleGeneration else { return }
                await store.saveMessage(m, countsAsUnread: false)
            }
        }
        guard lifecycle == lifecycleGeneration else { return }
        conversations = await store.allConversations()
        if let id = selectedId {
            await reloadVisibleMessages(for: id)
        }
        await enrichNames()
        guard lifecycle == lifecycleGeneration else { return }

        // Populate contact resolver from roster if using live backend
        if let live = service as? RustCoreService,
           let rosterData = try? await live.getRosterData() {
            await contactResolver.populateFromRoster(rosterData.contacts)
            await contactResolver.populateFromGroups(rosterData.groups)
        }

        guard lifecycle == lifecycleGeneration else { return }
        conversations = await store.allConversations()
        notifyStateChange()
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

    private func cancelOwnedTasks() async {
        let tasks = [observerTask, watchTask, autoFetchTask, rosterRefreshTask]
        let liveTasks = Array(liveFetchTasks.values)
        observerTask?.cancel()
        watchTask?.cancel()
        autoFetchTask?.cancel()
        rosterRefreshTask?.cancel()
        for task in liveFetchTasks.values { task.cancel() }
        liveFetchTasks.removeAll()
        observerTask = nil
        watchTask = nil
        autoFetchTask = nil
        rosterRefreshTask = nil
        for task in tasks {
            await task?.value
        }
        for task in liveTasks {
            await task.value
        }
    }

    /// Reset Swift-side state after the live service has already performed its
    /// logout/data wipe. This avoids issuing a second FFI logout, which is
    /// expected to return `not linked` after the first successful wipe.
    public func resetAfterServiceLogout() async throws {
        lifecycleGeneration += 1
        selectionGeneration += 1
        await cancelOwnedTasks()
        // The Rust Signal database and the Swift presentation database are
        // separate stores. Clear both so a relink cannot resurrect the prior
        // account's conversations, unread counts, or message UUIDs. The
        // encrypted presentation store uses its terminal path so its file and
        // database-scoped Keychain key can be removed after the queue closes.
        if let sqliteStore = store as? SQLiteMessageStore {
            try await sqliteStore.destroy()
        } else {
            try await store.clearAllDataChecked()
        }
        selfAci = nil
        lastSentThread = nil
        await contactResolver.clear()
        conversations = []
        messages = []
        selectedId = nil
        linkQR = nil
        lastSyncNote = nil
        lastError = nil
        connection = .unlinked
        notifyStateChange()
        Log.info("local controller state reset after service logout")
    }

    /// Authoritative logout + local/native wipe. Throwing prevents callers
    /// from starting a replacement account after a partial failure.
    public func logoutAndWipe() async throws {
        // Invalidate callbacks before the native wipe. A failed wipe returns
        // without clearing the presentation store or starting a new account.
        lifecycleGeneration += 1
        selectionGeneration += 1
        await cancelOwnedTasks()
        do {
            if let live = service as? RustCoreService {
                try await live.clearAllData()
            }
            try await resetAfterServiceLogout()
            Log.info("logged out")
        } catch {
            connection = .offline
            notifyStateChange()
            throw error
        }
    }

    /// Boolean compatibility wrapper for existing callers.
    public func logout() async -> Bool {
        do {
            try await logoutAndWipe()
            return true
        } catch {
            lastError = String(describing: error)
            Log.error("logout/data wipe failed: \(error)")
            return false
        }
    }

    /// Clear all local data (messages, conversations) without logging out from Signal.
    /// Used as part of full logout flow.
    public func clearAllData() async {
        await store.clearAllData()
        conversations = []
        messages = []
        selectedId = nil
        notifyStateChange()
        Log.info("ChatController: cleared all local data")
    }

    /// Send delivery receipts for incoming messages.
    public func sendDeliveryReceipts(
        for conversationId: String,
        timestamps: [Int64],
        authorID: String? = nil
    ) async throws {
        guard let live = service as? RustCoreService else {
            throw SignalError.unsupported("delivery receipts need the live backend")
        }
        guard !timestamps.isEmpty else { return }
        let targetThread: String
        if ThreadID.isGroup(conversationId) {
            guard let authorID, !authorID.isEmpty, authorID != "self" else {
                throw SignalError.unsupported("group delivery receipts require the message author")
            }
            targetThread = ThreadID.contactThreadId(uuid: authorID)
        } else {
            targetThread = conversationId
        }
        try await live.sendReceipt(thread: targetThread, timestamps: timestamps, kind: "delivered")
    }

    /// Send read receipts for all unread messages in a conversation.
    public func sendReadReceipts(for conversationId: String) async throws {
        guard let live = service as? RustCoreService else {
            throw SignalError.unsupported("read receipts need the live backend")
        }
        let messages = await store.messages(in: conversationId, limit: Int.max)
        let unreadMessages = messages.filter {
            $0.direction == .incoming && !$0.readBy.contains(selfAci ?? "")
        }
        let timestamps = unreadMessages.compactMap(\.storeTs)
        guard !timestamps.isEmpty else { return }

        if ThreadID.isGroup(conversationId) {
            // Signal group receipts are direct acknowledgements to each author;
            // broadcasting one receipt to the group is not equivalent.
            var byAuthor: [String: [Int64]] = [:]
            for message in unreadMessages {
                guard let author = message.author.uuidString,
                      !author.isEmpty,
                      author != "self",
                      let sts = message.storeTs else { continue }
                byAuthor[author, default: []].append(sts)
            }
            for (author, stamps) in byAuthor {
                try await live.sendReceipt(
                    thread: ThreadID.contactThreadId(uuid: author),
                    timestamps: stamps,
                    kind: "read"
                )
            }
        } else {
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
        let lifecycle = lifecycleGeneration
        selectedId = id
        // Top up from the service so threads opened after sync (or with
        // arrivals since sync) are complete; saveMessage dedupes by id.
        if let history = try? await service.fetchMessages(conversationId: id, limit: 200) {
            for m in history {
                guard generation == selectionGeneration, lifecycle == lifecycleGeneration else { return }
                await store.saveMessage(m, countsAsUnread: false)
            }
        }
        guard generation == selectionGeneration, lifecycle == lifecycleGeneration else { return }
        await store.markRead(conversationId: id)
        guard generation == selectionGeneration, lifecycle == lifecycleGeneration else { return }
        messages = await store.messages(in: id)
        guard generation == selectionGeneration, lifecycle == lifecycleGeneration else { return }
        if let idx = conversations.firstIndex(where: { $0.id == id }) {
            conversations[idx].unreadCount = 0
        }
        notifyStateChange()

        // Auto-send read receipts for unread messages in this conversation
        guard generation == selectionGeneration, lifecycle == lifecycleGeneration else { return }
        do {
            try await sendReadReceipts(for: id)
        } catch {
            Log.error("failed to send read receipts: \(error)")
        }
    }

    public func send(_ body: String, to requestedID: String? = nil) async {
        lastError = nil
        let lifecycle = lifecycleGeneration
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let id = requestedID ?? selectedId else { return }
        do {
            let msg = try await service.sendText(trimmed, to: id)
            guard lifecycle == lifecycleGeneration else { return }
            lastSentThread = id
            await store.saveMessage(msg)
            guard lifecycle == lifecycleGeneration else { return }
            await reloadVisibleMessages(for: id)
            conversations = await store.allConversations()
            notifyStateChange()
            Log.info("sent \(trimmed.count) chars to \(id)")
        } catch {
            lastError = String(describing: error)
            Log.error("send failed: \(error)")
        }
    }

    /// Send text, or run a `/command` through `plugins` (reply is ephemeral).
    /// The target is captured by the caller so a command cannot follow a
    /// later conversation selection while an async plugin is running.
    public func sendOrCommand(
        _ body: String,
        plugins: PluginHost,
        ctx: PluginContext,
        to requestedID: String? = nil
    ) async {
        let targetID = requestedID ?? selectedId
        if body.hasPrefix("/") {
            switch await plugins.handleInput(body, ctx: ctx) {
            case .sendOriginal:
                break
            case .reply(let text):
                await injectEphemeral(text, threadId: targetID)
                return
            case .silent:
                return
            }
        }
        await send(body, to: targetID)
    }

    /// Grow the open thread by one more history page. The boolean wrapper is
    /// retained for existing callers; new code should use the typed result to
    /// distinguish exhausted, failed, and cancelled operations.
    @discardableResult
    public func loadMore(chunk: Int = 100) async -> Bool {
        if case .loaded = await loadMoreResult(chunk: chunk) {
            return true
        }
        return false
    }

    public func loadMoreResult(chunk: Int = 100) async -> LoadMoreResult {
        guard let id = selectedId, chunk > 0 else { return .exhausted }
        let selection = selectionGeneration
        let lifecycle = lifecycleGeneration
        let current = await store.messageCount(in: id)
        do {
            let merged = try await service.fetchMessages(
                conversationId: id,
                limit: current + max(0, chunk)
            )
            for m in merged {
                guard selectedId == id,
                      selection == selectionGeneration,
                      lifecycle == lifecycleGeneration else { return .cancelled }
                await store.saveMessage(m, countsAsUnread: false)
            }
            let after = await store.messageCount(in: id)
            guard selectedId == id,
                  selection == selectionGeneration,
                  lifecycle == lifecycleGeneration else { return .cancelled }
            messages = await store.messages(in: id, limit: max(200, after))
            let grew = after > current
            notifyStateChange()
            Log.info("loadMore \(id): \(current) -> \(after)")
            return grew ? .loaded : .exhausted
        } catch {
            guard selectedId == id,
                  selection == selectionGeneration,
                  lifecycle == lifecycleGeneration else { return .cancelled }
            let message = String(describing: error)
            lastError = message
            Log.error("loadMore failed: \(error)")
            return .failed(message)
        }
    }

    public func messages(in id: String, limit: Int = 200) async -> [ChatMessage] {
        await store.messages(in: id, limit: limit)
    }

    /// On-demand attachment download for metadata-only rows.
    @discardableResult
    public func downloadAttachment(messageId: UUID, index: Int) async -> Bool {
        let lifecycle = lifecycleGeneration
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
            guard lifecycle == lifecycleGeneration else { return false }
            live.bindLocalPath(thread: stored.conversationId, ts: sts, index: index, path: url.path)
            await store.updateMessage(id: messageId) { $0.attachments[index].localURL = url }
            await reloadVisibleMessages(for: stored.conversationId)
            notifyStateChange()
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
        let lifecycle = lifecycleGeneration
        // Reactions/control envelopes are delivered separately by the native
        // core. A legacy empty payload must never become a blank chat bubble.
        if message.direction == .incoming,
           message.body.isEmpty,
           message.attachments.isEmpty,
           message.replyTo == nil {
            return
        }
        guard lifecycle == lifecycleGeneration else { return }
        if message.direction == .incoming,
           !conversations.contains(where: { $0.id == message.conversationId }) {
            let peer = ThreadID.signalAddress(from: message.conversationId)
            let title = message.author.displayName ?? peer.displayKey
            await store.upsertConversation(Conversation(
                id: message.conversationId,
                title: title,
                peer: peer,
                lastMessagePreview: String(message.body.prefix(120)),
                lastActiveAt: message.sentAt,
                unreadCount: 0
            ))
        }
        guard lifecycle == lifecycleGeneration else { return }
        let inserted = await store.saveMessage(message, countsAsUnread: true)
        guard lifecycle == lifecycleGeneration else { return }
        conversations = await store.allConversations()
        await reloadVisibleMessages(for: message.conversationId)
        guard lifecycle == lifecycleGeneration else { return }
        notifyStateChange()
        if inserted && message.direction == .incoming {
            onIncomingMessage?(message)
            scheduleLiveAttachmentFetch(for: message.id)
        }

        // Auto-send delivery receipt for incoming messages
        if lifecycle == lifecycleGeneration,
           message.direction == .incoming, let sts = message.storeTs {
            do {
                try await sendDeliveryReceipts(
                    for: message.conversationId,
                    timestamps: [sts],
                    authorID: message.author.uuidString
                )
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

    private func scheduleLiveAttachmentFetch(for messageID: UUID) {
        guard service is RustCoreService, liveFetchTasks[messageID] == nil else { return }
        let lifecycle = lifecycleGeneration
        liveFetchTasks[messageID] = Task { @MainActor [weak self] in
            await self?.autoFetchMessage(messageID, lifecycle: lifecycle)
            self?.liveFetchTasks[messageID] = nil
        }
    }

    private func autoFetchMessage(_ messageID: UUID, lifecycle: Int) async {
        guard lifecycle == lifecycleGeneration,
              let message = await store.message(id: messageID) else { return }
        var fetched = 0
        for index in message.attachments.indices {
            guard lifecycle == lifecycleGeneration, fetched < 4 else { return }
            let attachment = message.attachments[index]
            guard (attachment.isImage || attachment.isVideo),
                  attachment.localURL == nil,
                  attachment.byteCount > 0,
                  attachment.byteCount <= 25_000_000 else { continue }
            if await downloadAttachment(messageId: messageID, index: index) {
                fetched += 1
            }
        }
    }

    /// Auto-fetch missing attachments after launch (roster seeds metadata
    /// only). Media (images/video, incl. GIFs) fetch automatically; other
    /// file types stay manual. Bounded: newest-first, capped count.
    /// Fire-and-forget from `finish()`; failures stay quiet in the log.
    public func autoFetchMissing(maxFiles: Int = 20) async {
        let lifecycle = lifecycleGeneration
        guard service is RustCoreService else { return }
        var fetched = 0
        for conv in conversations {
            guard lifecycle == lifecycleGeneration else { return }
            if fetched >= maxFiles { break }
            let list = await store.messages(in: conv.id)
            for m in list.reversed() {
                guard lifecycle == lifecycleGeneration else { return }
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
                    guard !stillHasFile,
                          att.isImage || att.isVideo,
                          att.byteCount > 0,
                          att.byteCount <= 25_000_000 else { continue }
                    if await downloadAttachment(messageId: m.id, index: idx) {
                        fetched += 1
                    }
                }
            }
        }
        if fetched > 0, let selectedId, lifecycle == lifecycleGeneration {
            await reloadVisibleMessages(for: selectedId)
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
            notifyStateChange()
        }
    }

    private func notifyStateChange() {
        onStateChange?()
    }

    private func observeConnection() {
        observerTask?.cancel()
        observerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let lifecycle = self.lifecycleGeneration
            for await state in self.service.connectionState {
                guard !Task.isCancelled, self.lifecycleGeneration == lifecycle else { return }
                // Terminal .connected from waitForLink wins; only surface
                // regressions (offline) from the backend.
                if state == .offline {
                    self.connection = .offline
                    self.notifyStateChange()
                }
            }
        }
    }
}

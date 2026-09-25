import Foundation

/// Protocol for message storage. Implemented by both `InMemoryMessageStore`
/// (M0/M1, tests) and `SQLiteMessageStore` (M2+, production).
///
/// All methods are async to unify the interface — the in-memory implementation
/// simply doesn't await.
public protocol MessageStoring: Actor {
    func upsertConversation(_ conversation: Conversation) async
    func allConversations() async -> [Conversation]
    /// Persist a message and return true only when it was not already
    /// present. This is used to avoid duplicate live notifications.
    @discardableResult
    func saveMessage(_ message: ChatMessage) async -> Bool
    /// Persist a message while optionally counting it as a new unread arrival.
    /// Historical/roster imports pass `false`; live inbound messages pass `true`.
    @discardableResult
    func saveMessage(_ message: ChatMessage, countsAsUnread: Bool) async -> Bool
    func markRead(conversationId: String) async
    func messages(in conversationId: String, limit: Int) async -> [ChatMessage]
    func messages(in conversationId: String) async -> [ChatMessage]
    func messageCount(in conversationId: String) async -> Int
    func message(id: UUID) async -> ChatMessage?
    /// Find a message by its stable native store timestamp, including rows
    /// outside the current UI page.
    func message(conversationId: String, storeTs: Int64) async -> ChatMessage?
    @discardableResult
    func updateMessage(id: UUID, transform: @escaping @Sendable (inout ChatMessage) -> Void) async -> Bool
    func deleteMessage(id: UUID) async -> ChatMessage?
    /// Delete a message by thread and stable native store timestamp.
    func deleteMessage(conversationId: String, storeTs: Int64) async -> ChatMessage?
    func renameConversation(id: String, title: String) async
    func totalMessageCount() async -> Int
    func searchConversations(query: String) async -> [Conversation]
    func deleteConversation(id: String) async
    /// Delete all stored data (messages, conversations, attachments). Used on logout.
    func clearAllData() async
    /// Failure-aware wipe used by the authoritative logout path.
    func clearAllDataChecked() async throws
}

/// M0 in-memory store. Implements `MessageStoring` so M2 can swap
/// the backend to `SQLiteMessageStore` / GRDB without touching ViewModels.
///
/// Thread-safety: actor. All models are Sendable/Codable for FFI later.
public actor InMemoryMessageStore: MessageStoring {
    private var conversations: [String: Conversation] = [:]
    private var messages: [String: [ChatMessage]] = [:]

    public init() {}
    public init(seed: [Conversation], messages seedMessages: [ChatMessage] = []) {
        for c in seed { conversations[c.id] = c }
        for m in seedMessages {
            messages[m.conversationId, default: []].append(m)
        }
    }

    public func upsertConversation(_ conversation: Conversation) async {
        var updated = conversation
        // A profile lookup may have produced a better title than the raw
        // roster row. Do not replace that title with `Unknown`, a phone
        // number, or a service-id prefix on the next refresh.
        if let existing = conversations[conversation.id] {
            if Self.isPlaceholderTitle(updated.title),
               !Self.isPlaceholderTitle(existing.title) {
                updated.title = existing.title
            }
            // Roster metadata is not authoritative for local read/activity
            // state. Never let a refresh roll those values backward.
            let hasNewerActivity = updated.lastActiveAt > existing.lastActiveAt
            updated.unreadCount = max(updated.unreadCount, existing.unreadCount)
            updated.lastActiveAt = max(updated.lastActiveAt, existing.lastActiveAt)
            if updated.lastMessagePreview == nil || !hasNewerActivity {
                updated.lastMessagePreview = existing.lastMessagePreview
            }
        }
        conversations[conversation.id] = updated
    }

    public func allConversations() async -> [Conversation] {
        conversations.values.sorted { $0.lastActiveAt > $1.lastActiveAt }
    }

    @discardableResult
    public func saveMessage(_ message: ChatMessage) async -> Bool {
        await saveMessage(message, countsAsUnread: true)
    }

    @discardableResult
    public func saveMessage(_ message: ChatMessage, countsAsUnread: Bool) async -> Bool {
        // Re-syncs can present the same message with a newly generated local
        // UUID. Prefer the store timestamp + author + content identity so the
        // UI and unread count remain idempotent across startup refreshes.
        let existingIndex = messages[message.conversationId]?.firstIndex { existing in
            if existing.id == message.id { return true }
            guard let storeTs = message.storeTs,
                  storeTs > 0,
                  existing.storeTs == storeTs,
                  existing.direction == message.direction else { return false }
            return existing.author.uuidString == message.author.uuidString
                || (message.direction == .outgoing
                    && (existing.author.uuidString == "self" || message.author.uuidString == "self"))
        }
        let isNew = existingIndex == nil
        if let idx = existingIndex {
            let existing = messages[message.conversationId]![idx]
            var merged = Self.merge(existing: existing, incoming: message)
            merged.id = existing.id
            messages[message.conversationId]?[idx] = merged
        } else {
            messages[message.conversationId, default: []].append(message)
        }
        if var conv = conversations[message.conversationId] {
            // Older replays must not roll the sidebar preview backward.
            if message.sentAt >= conv.lastActiveAt {
                conv.lastMessagePreview = String(message.body.prefix(120))
                conv.lastActiveAt = message.sentAt
            }
            if isNew && countsAsUnread && message.direction == .incoming {
                conv.unreadCount += 1
            }
            conversations[message.conversationId] = conv
        }
        return isNew
    }

    private static func merge(existing: ChatMessage, incoming: ChatMessage) -> ChatMessage {
        var merged = incoming
        merged.reactions = orderedUnion(existing.reactions, incoming.reactions)
        merged.readBy = orderedUnion(existing.readBy, incoming.readBy)
        merged.deliveredTo = orderedUnion(existing.deliveredTo, incoming.deliveredTo)
        if incoming.status == .queued, existing.status != .queued {
            merged.status = existing.status
        } else if existing.status == .failed, incoming.status == .sent {
            merged.status = .failed
        }
        if incoming.author.displayName?.isEmpty != false {
            merged.author.displayName = existing.author.displayName
        }
        if incoming.replyTo == nil {
            merged.replyTo = existing.replyTo
        }
        if incoming.attachments.isEmpty {
            merged.attachments = existing.attachments
        } else if !existing.attachments.isEmpty {
            for index in merged.attachments.indices where merged.attachments[index].localURL == nil
                && index < existing.attachments.count {
                merged.attachments[index].localURL = existing.attachments[index].localURL
            }
        }
        return merged
    }

    public func markRead(conversationId: String) async {
        if var conv = conversations[conversationId] {
            conv.unreadCount = 0
            conversations[conversationId] = conv
        }
    }

    public func messages(in conversationId: String, limit: Int = 200) async -> [ChatMessage] {
        let all = (messages[conversationId] ?? []).sorted { $0.sentAt < $1.sentAt }
        return Array(all.suffix(max(0, limit)))
    }

    public func messages(in conversationId: String) async -> [ChatMessage] {
        await messages(in: conversationId, limit: 200)
    }

    public func messageCount(in conversationId: String) async -> Int {
        messages[conversationId]?.count ?? 0
    }

    public func message(id: UUID) async -> ChatMessage? {
        for list in messages.values {
            if let found = list.first(where: { $0.id == id }) {
                return found
            }
        }
        return nil
    }

    public func message(conversationId: String, storeTs: Int64) async -> ChatMessage? {
        messages[conversationId]?.first(where: { $0.storeTs == storeTs })
    }

    /// Replace a message in place (attachment progress, status updates).
    /// Returns false when the id is unknown.
    @discardableResult
    public func updateMessage(id: UUID, transform: @Sendable (inout ChatMessage) -> Void) async -> Bool {
        for (thread, var list) in messages {
            if let idx = list.firstIndex(where: { $0.id == id }) {
                transform(&list[idx])
                messages[thread] = list
                if var conversation = conversations[thread] {
                    let latest = list.sorted { $0.sentAt < $1.sentAt }.last
                    conversation.lastMessagePreview = latest.map { String($0.body.prefix(120)) }
                    conversation.lastActiveAt = latest?.sentAt ?? conversation.lastActiveAt
                    conversations[thread] = conversation
                }
                return true
            }
        }
        return false
    }

    /// Remove a message by id, returning it (for remote delete flows).
    public func deleteMessage(id: UUID) async -> ChatMessage? {
        for (thread, var list) in messages {
            if let idx = list.firstIndex(where: { $0.id == id }) {
                let removed = list.remove(at: idx)
                messages[thread] = list
                if var conversation = conversations[thread] {
                    let latest = list.sorted { $0.sentAt < $1.sentAt }.last
                    conversation.lastMessagePreview = latest.map { String($0.body.prefix(120)) }
                    conversation.lastActiveAt = latest?.sentAt ?? .distantPast
                    if removed.direction == .incoming {
                        conversation.unreadCount = max(0, conversation.unreadCount - 1)
                    }
                    conversations[thread] = conversation
                }
                return removed
            }
        }
        return nil
    }

    public func deleteMessage(conversationId: String, storeTs: Int64) async -> ChatMessage? {
        guard var list = messages[conversationId],
              let index = list.firstIndex(where: { $0.storeTs == storeTs }) else {
            return nil
        }
        let removed = list.remove(at: index)
        messages[conversationId] = list
        if var conversation = conversations[conversationId] {
            let remaining = list.sorted { $0.sentAt < $1.sentAt }
            conversation.lastMessagePreview = remaining.last.map { String($0.body.prefix(120)) }
            conversation.lastActiveAt = remaining.last?.sentAt ?? .distantPast
            if removed.direction == .incoming { conversation.unreadCount = max(0, conversation.unreadCount - 1) }
            conversations[conversationId] = conversation
        }
        return removed
    }

    public func renameConversation(id: String, title: String) async {
        if var conv = conversations[id] {
            conv.title = title
            conversations[id] = conv
        }
    }

    public func totalMessageCount() async -> Int {
        messages.values.reduce(0) { $0 + $1.count }
    }

    public func searchConversations(query: String) async -> [Conversation] {
        let q = query.lowercased()
        guard !q.isEmpty else { return await allConversations() }
        return conversations.values
            .filter {
                $0.title.lowercased().contains(q)
                    || ($0.peer.phone?.lowercased().contains(q) ?? false)
                    || ($0.peer.groupId?.lowercased().contains(q) ?? false)
            }
            .sorted { $0.lastActiveAt > $1.lastActiveAt }
    }

    public func deleteConversation(id: String) async {
        conversations.removeValue(forKey: id)
        messages.removeValue(forKey: id)
    }

    public func clearAllData() async {
        try? await clearAllDataChecked()
    }

    public func clearAllDataChecked() async throws {
        conversations.removeAll()
        messages.removeAll()
    }

    private static func orderedUnion<T: Hashable>(_ first: [T], _ second: [T]) -> [T] {
        var result = first
        for value in second where !result.contains(value) {
            result.append(value)
        }
        return result
    }

    private static func isPlaceholderTitle(_ title: String) -> Bool {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty
            || value == "Unknown"
            || value.hasPrefix("+")
            || value.count == 8
            || UUID(uuidString: value) != nil
    }
}

/// Typealias for backward compatibility — existing code using `MessageStore`
/// continues to work (refers to `InMemoryMessageStore`).
public typealias MessageStore = InMemoryMessageStore
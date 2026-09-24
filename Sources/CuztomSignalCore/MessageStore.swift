import Foundation

/// Protocol for message storage. Implemented by both `InMemoryMessageStore`
/// (M0/M1, tests) and `SQLiteMessageStore` (M2+, production).
///
/// All methods are async to unify the interface — the in-memory implementation
/// simply doesn't await.
public protocol MessageStoring: Actor {
    func upsertConversation(_ conversation: Conversation) async
    func allConversations() async -> [Conversation]
    func saveMessage(_ message: ChatMessage) async
    func markRead(conversationId: String) async
    func messages(in conversationId: String, limit: Int) async -> [ChatMessage]
    func messages(in conversationId: String) async -> [ChatMessage]
    func messageCount(in conversationId: String) async -> Int
    func message(id: UUID) async -> ChatMessage?
    @discardableResult
    func updateMessage(id: UUID, transform: @escaping @Sendable (inout ChatMessage) -> Void) async -> Bool
    func deleteMessage(id: UUID) async -> ChatMessage?
    func renameConversation(id: String, title: String) async
    func totalMessageCount() async -> Int
    func searchConversations(query: String) async -> [Conversation]
    func deleteConversation(id: String) async
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
        conversations[conversation.id] = conversation
    }

    public func allConversations() async -> [Conversation] {
        conversations.values.sorted { $0.lastActiveAt > $1.lastActiveAt }
    }

    public func saveMessage(_ message: ChatMessage) async {
        // Idempotent: re-syncing a thread replaces existing rows by id.
        if let idx = messages[message.conversationId]?.firstIndex(where: { $0.id == message.id }) {
            messages[message.conversationId]?[idx] = message
        } else {
            messages[message.conversationId, default: []].append(message)
        }
        if var conv = conversations[message.conversationId] {
            conv.lastMessagePreview = String(message.body.prefix(120))
            conv.lastActiveAt = max(conv.lastActiveAt, message.sentAt)
            if message.direction == .incoming {
                conv.unreadCount += 1
            }
            conversations[message.conversationId] = conv
        }
    }

    public func markRead(conversationId: String) async {
        if var conv = conversations[conversationId] {
            conv.unreadCount = 0
            conversations[conversationId] = conv
        }
    }

    public func messages(in conversationId: String, limit: Int = 200) async -> [ChatMessage] {
        let all = (messages[conversationId] ?? []).sorted { $0.sentAt < $1.sentAt }
        return Array(all.suffix(limit))
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

    /// Replace a message in place (attachment progress, status updates).
    /// Returns false when the id is unknown.
    @discardableResult
    public func updateMessage(id: UUID, transform: @Sendable (inout ChatMessage) -> Void) async -> Bool {
        for (thread, var list) in messages {
            if let idx = list.firstIndex(where: { $0.id == id }) {
                transform(&list[idx])
                messages[thread] = list
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
                return removed
            }
        }
        return nil
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
}

/// Typealias for backward compatibility — existing code using `MessageStore`
/// continues to work (refers to `InMemoryMessageStore`).
public typealias MessageStore = InMemoryMessageStore
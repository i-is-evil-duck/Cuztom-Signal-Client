import Foundation

/// M0 in-memory store. API is intentionally SQLite-shaped so M2 can swap
/// the backend to `presage-store-sqlite` / GRDB without touching ViewModels.
///
/// Thread-safety: actor. All models are Sendable/Codable for FFI later.
public actor MessageStore {
    private var conversations: [String: Conversation] = [:]
    private var messages: [String: [ChatMessage]] = [:]

    public init() {}
    public init(seed: [Conversation], messages seedMessages: [ChatMessage] = []) {
        for c in seed { conversations[c.id] = c }
        for m in seedMessages {
            messages[m.conversationId, default: []].append(m)
        }
    }

    public func upsertConversation(_ conversation: Conversation) {
        conversations[conversation.id] = conversation
    }

    public func allConversations() -> [Conversation] {
        conversations.values.sorted { $0.lastActiveAt > $1.lastActiveAt }
    }

    public func saveMessage(_ message: ChatMessage) {
        messages[message.conversationId, default: []].append(message)
        if var conv = conversations[message.conversationId] {
            conv.lastMessagePreview = String(message.body.prefix(120))
            conv.lastActiveAt = max(conv.lastActiveAt, message.sentAt)
            if message.direction == .incoming {
                conv.unreadCount += 1
            }
            conversations[message.conversationId] = conv
        }
    }

    public func markRead(conversationId: String) {
        if var conv = conversations[conversationId] {
            conv.unreadCount = 0
            conversations[conversationId] = conv
        }
    }

    public func messages(in conversationId: String, limit: Int = 200) -> [ChatMessage] {
        let all = (messages[conversationId] ?? []).sorted { $0.sentAt < $1.sentAt }
        return Array(all.suffix(limit))
    }

    public func messageCount(in conversationId: String) -> Int {
        messages[conversationId]?.count ?? 0
    }
}

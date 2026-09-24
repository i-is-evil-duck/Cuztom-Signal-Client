import Foundation

/// Stable identity for a 1:1 peer or a group.
public struct SignalAddress: Hashable, Sendable, Codable {
    public var uuidString: String?
    public var phone: String?
    public var groupId: String?

    public init(uuidString: String? = nil, phone: String? = nil, groupId: String? = nil) {
        self.uuidString = uuidString
        self.phone = phone
        self.groupId = groupId
    }

    public var isGroup: Bool { groupId != nil }

    public var displayKey: String {
        groupId ?? uuidString ?? phone ?? "unknown"
    }
}

public enum MessageDirection: String, Sendable, Codable {
    case incoming, outgoing
}

public enum MessageStatus: String, Sendable, Codable {
    case queued, sent, delivered, read, failed
}

public struct AttachmentMeta: Sendable, Codable, Hashable {
    public var filename: String
    public var mimeType: String
    public var byteCount: Int
    public var localURL: URL?

    public init(filename: String, mimeType: String, byteCount: Int, localURL: URL? = nil) {
        self.filename = filename
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.localURL = localURL
    }
}

public struct ChatMessage: Identifiable, Sendable, Codable {
    public var id: UUID
    public var conversationId: String
    public var author: SignalAddress
    public var body: String
    public var direction: MessageDirection
    public var status: MessageStatus
    public var sentAt: Date
    public var attachments: [AttachmentMeta]
    /// Store-clock timestamp (SQLite `ts` column basis) for paging/lookup.
    /// Nil for mock/local messages, which page trivially.
    public var storeTs: Int64?

    public init(
        id: UUID = UUID(),
        conversationId: String,
        author: SignalAddress,
        body: String,
        direction: MessageDirection,
        status: MessageStatus = .queued,
        sentAt: Date = Date(),
        attachments: [AttachmentMeta] = [],
        storeTs: Int64? = nil
    ) {
        self.id = id
        self.conversationId = conversationId
        self.author = author
        self.body = body
        self.direction = direction
        self.status = status
        self.sentAt = sentAt
        self.attachments = attachments
        self.storeTs = storeTs
    }
}

public struct Conversation: Identifiable, Sendable, Codable {
    public var id: String
    public var title: String
    public var peer: SignalAddress
    public var lastMessagePreview: String?
    public var lastActiveAt: Date
    public var unreadCount: Int

    public init(
        id: String,
        title: String,
        peer: SignalAddress,
        lastMessagePreview: String? = nil,
        lastActiveAt: Date = Date(),
        unreadCount: Int = 0
    ) {
        self.id = id
        self.title = title
        self.peer = peer
        self.lastMessagePreview = lastMessagePreview
        self.lastActiveAt = lastActiveAt
        self.unreadCount = unreadCount
    }
}

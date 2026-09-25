import Foundation

/// Stable identity for a 1:1 peer or a group.
public struct SignalAddress: Hashable, Sendable, Codable {
    public var uuidString: String?
    public var phone: String?
    /// Group master key (hex) - only set for groups, not the full thread ID
    public var groupId: String?
    /// Full thread identifier: "contact:<uuid>" or "group:<master_key_hex>"
    public var threadId: String?
    /// Best-effort friendly name supplied by the authenticated message or
    /// call envelope. Roster/profile resolution may replace it later.
    public var displayName: String?

    public init(
        uuidString: String? = nil,
        phone: String? = nil,
        groupId: String? = nil,
        threadId: String? = nil,
        displayName: String? = nil
    ) {
        self.uuidString = uuidString
        self.phone = phone
        self.groupId = groupId
        self.threadId = threadId
        self.displayName = displayName
    }

    public var isGroup: Bool { groupId != nil }

    /// Key for display/lookup: group master key, or contact UUID/phone
    public var displayKey: String {
        groupId ?? uuidString ?? phone ?? "unknown"
    }

    /// Create a SignalAddress from a thread ID string
    public static func from(threadId: String) -> SignalAddress {
        if threadId.hasPrefix("group:") {
            let masterKey = String(threadId.dropFirst(6)) // Remove "group:" prefix
            return SignalAddress(groupId: masterKey, threadId: threadId)
        } else if threadId.hasPrefix("contact:") {
            let uuid = String(threadId.dropFirst(8)) // Remove "contact:" prefix
            return SignalAddress(uuidString: uuid, threadId: threadId)
        } else {
            // Fallback - treat as UUID
            return SignalAddress(uuidString: threadId, threadId: threadId)
        }
    }

    /// Get the thread ID, deriving from components if not explicitly set
    public var effectiveThreadId: String {
        threadId ?? (groupId.map { "group:\($0)" } ?? uuidString.map { "contact:\($0)" } ?? "unknown")
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

    /// MIME values from Signal/CDNs may include parameters or a generic
    /// binary type. Normalize them and use the filename/cache extension as a
    /// fallback for older roster rows.
    public var normalizedMIMEType: String {
        let raw = mimeType
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        if !raw.isEmpty && raw != "application/octet-stream" && raw != "binary/octet-stream" {
            return raw
        }
        let ext = (localURL?.pathExtension ?? (filename as NSString).pathExtension).lowercased()
        switch ext {
        case "gif": return "image/gif"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "mp4", "m4v", "mov": return "video/mp4"
        case "webm": return "video/webm"
        case "mp3", "m4a", "aac", "wav": return "audio/mpeg"
        case "pdf": return "application/pdf"
        default: return raw.isEmpty ? "application/octet-stream" : raw
        }
    }

    public var isImage: Bool { normalizedMIMEType.hasPrefix("image/") }
    public var isVideo: Bool { normalizedMIMEType.hasPrefix("video/") }
    public var isGIF: Bool {
        normalizedMIMEType == "image/gif"
            || localURL?.pathExtension.lowercased() == "gif"
            || (filename as NSString).pathExtension.lowercased() == "gif"
    }
}

/// Stable reference to the message quoted by a reply. The native protocol
/// identifies the target by store timestamp and author, not the Swift UUID.
public struct MessageReference: Identifiable, Hashable, Sendable, Codable {
    public var storeTs: Int64
    public var authorID: String?
    public var body: String?

    public var id: String {
        "\(storeTs):\(authorID ?? "")"
    }

    public init(storeTs: Int64, authorID: String? = nil, body: String? = nil) {
        self.storeTs = storeTs
        self.authorID = authorID
        self.body = body
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
    /// Optional quoted-message reference for reply rendering/navigation.
    public var replyTo: MessageReference?
    /// Store-clock timestamp (SQLite `ts` column basis) for paging/lookup.
    /// Nil for mock/local messages, which page trivially.
    public var storeTs: Int64?
    /// Emoji reactions on this message (display only).
    public var reactions: [String] = []
    /// Display names that have read this message (own messages).
    public var readBy: [String] = []
    /// Display names whose devices confirmed delivery (own messages).
    public var deliveredTo: [String] = []

    public init(
        id: UUID = UUID(),
        conversationId: String,
        author: SignalAddress,
        body: String,
        direction: MessageDirection,
        status: MessageStatus = .queued,
        sentAt: Date = Date(),
        attachments: [AttachmentMeta] = [],
        replyTo: MessageReference? = nil,
        storeTs: Int64? = nil,
        reactions: [String] = [],
        readBy: [String] = [],
        deliveredTo: [String] = []
    ) {
        self.id = id
        self.conversationId = conversationId
        self.author = author
        self.body = body
        self.direction = direction
        self.status = status
        self.sentAt = sentAt
        self.attachments = attachments
        self.replyTo = replyTo
        self.storeTs = storeTs
        self.reactions = reactions
        self.readBy = readBy
        self.deliveredTo = deliveredTo
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

// MARK: - Call Models (M4)

/// Media type for a call
public enum CallMediaType: String, Sendable, Codable {
    case voice
    case video
}

/// Direction of a call
public enum CallDirection: String, Sendable, Codable {
    case incoming
    case outgoing
}

/// Current state of a call
public enum CallState: String, Sendable, Codable {
    case idle
    case dialing      // Outgoing: connecting
    case ringing      // Incoming: phone ringing
    case connecting   // Both: WebRTC connecting (ICE/DTLS)
    case active       // Connected, media flowing
    case ending       // Locally initiated hangup
    case ended        // Call finished
}

/// Reason a call ended
public enum CallEndReason: String, Sendable, Codable {
    case localHangup
    case remoteHangup
    case missed
    case failed
    case declined
    case timeout
    case noAnswer
}

/// Call metadata for UI and history
public struct CallRecord: Identifiable, Sendable, Codable {
    public var id: UUID
    public var conversationId: String
    public var direction: CallDirection
    public var mediaType: CallMediaType
    public var state: CallState
    public var startTime: Date?
    public var connectTime: Date?
    public var endTime: Date?
    public var endReason: CallEndReason?
    public var remotePeer: SignalAddress

    public init(
        id: UUID = UUID(),
        conversationId: String,
        direction: CallDirection,
        mediaType: CallMediaType,
        state: CallState = .idle,
        startTime: Date? = nil,
        connectTime: Date? = nil,
        endTime: Date? = nil,
        endReason: CallEndReason? = nil,
        remotePeer: SignalAddress
    ) {
        self.id = id
        self.conversationId = conversationId
        self.direction = direction
        self.mediaType = mediaType
        self.state = state
        self.startTime = startTime
        self.connectTime = connectTime
        self.endTime = endTime
        self.endReason = endReason
        self.remotePeer = remotePeer
    }

    public var duration: TimeInterval? {
        guard let start = connectTime, let end = endTime else { return nil }
        return end.timeIntervalSince(start)
    }
}

/// Active call session (for in-progress calls)
public struct ActiveCall: Sendable {
    public var callRecord: CallRecord
    public var localVideoEnabled: Bool = true
    public var remoteVideoEnabled: Bool = false
    public var muted: Bool = false
    public var speakerOn: Bool = false

    public init(callRecord: CallRecord) {
        self.callRecord = callRecord
    }
}

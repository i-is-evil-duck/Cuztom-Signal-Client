import Foundation
import GRDB

/// SQLite-backed MessageStore using GRDB. Implements `MessageStoring`
/// so it can replace `InMemoryMessageStore` without touching the controller.
///
/// Schema:
/// - conversations: id (PK), title, peer_json, lastMessagePreview, lastActiveAt, unreadCount
/// - messages: id (PK), conversationId (FK), author_json, body, direction, status,
///             sentAt, attachments_json, storeTs, reactions_json, readBy_json, deliveredTo_json
///
/// Indexes on messages(conversationId, sentAt) for paging.
public actor SQLiteMessageStore: MessageStoring {
    private let dbQueue: DatabaseQueue
    private let path: URL

    public init(path: URL? = nil) throws {
        let base: URL
        if let path = path {
            base = path
        } else {
            base = try FileManager.default
                .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("CuztomSignal", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let dbPath = base.appendingPathComponent("messages.sqlite")
        self.path = dbPath
        self.dbQueue = try DatabaseQueue(path: dbPath.path)
        try dbQueue.write { db in
            try Self.migrate(db)
        }
    }

    private static func migrate(_ db: Database) throws {
        try db.create(table: "conversations", ifNotExists: true) { t in
            t.column("id", .text).primaryKey()
            t.column("title", .text).notNull()
            t.column("peer_json", .text).notNull()
            t.column("lastMessagePreview", .text)
            t.column("lastActiveAt", .double).notNull()
            t.column("unreadCount", .integer).notNull().defaults(to: 0)
        }
        try db.create(table: "messages", ifNotExists: true) { t in
            t.column("id", .text).primaryKey()
            t.column("conversationId", .text).notNull().indexed()
            t.column("author_json", .text).notNull()
            t.column("body", .text).notNull()
            t.column("direction", .text).notNull()
            t.column("status", .text).notNull()
            t.column("sentAt", .double).notNull()
            t.column("attachments_json", .text).notNull()
            t.column("storeTs", .integer)
            t.column("reactions_json", .text).notNull()
            t.column("readBy_json", .text).notNull()
            t.column("deliveredTo_json", .text).notNull()
        }
        try db.create(index: "idx_messages_conversation_sentAt", on: "messages", columns: ["conversationId", "sentAt"], ifNotExists: true)
        // Reaction, delete, and other control envelopes can be stored as
        // empty DataMessages by older roster builders. They are not chat
        // messages and must not acquire a sender chip in the UI.
        try db.execute(sql: """
            DELETE FROM messages
            WHERE storeTs IS NOT NULL
              AND body = ''
              AND COALESCE(json_array_length(attachments_json), 0) = 0
            """)
        // Older builds could persist the same Signal message under two local
        // UUIDs when roster and live delivery arrived during startup. Keep the
        // earliest row for each stable message identity before the UI loads.
        try db.execute(sql: """
            DELETE FROM messages
            WHERE storeTs IS NOT NULL
              AND rowid NOT IN (
                SELECT MIN(rowid) FROM messages
                WHERE storeTs IS NOT NULL
                GROUP BY conversationId, storeTs, direction,
                    CASE
                        WHEN body = '[attachment]' AND COALESCE(json_array_length(attachments_json), 0) > 0 THEN ''
                        ELSE body
                    END,
                    CASE
                        WHEN direction = 'outgoing' THEN ''
                        ELSE lower(coalesce(json_extract(author_json, '$.uuidString'), ''))
                    END
              )
            """)
    }

    // MARK: - Conversations

    public func upsertConversation(_ conversation: Conversation) async {
        do {
            try await dbQueue.write { db in
                try Self.upsertConversation(db, conversation)
            }
        } catch {
            Log.error("upsertConversation failed: \(error)")
        }
    }

    private static func upsertConversation(_ db: Database, _ conversation: Conversation) throws {
        var c = conversation
        let oldTitle = try String.fetchOne(
            db,
            sql: "SELECT title FROM conversations WHERE id = ?",
            arguments: [c.id]
        )
        if let oldTitle,
           isPlaceholderTitle(c.title),
           !isPlaceholderTitle(oldTitle) {
            c.title = oldTitle
        }
        let peerData = try JSONEncoder().encode(c.peer)
        let peerJSON = String(data: peerData, encoding: .utf8)!
        try db.execute(
            sql: """
            INSERT INTO conversations (id, title, peer_json, lastMessagePreview, lastActiveAt, unreadCount)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                title = excluded.title,
                peer_json = excluded.peer_json,
                lastMessagePreview = excluded.lastMessagePreview,
                lastActiveAt = excluded.lastActiveAt,
                unreadCount = excluded.unreadCount
            """,
            arguments: [c.id, c.title, peerJSON, c.lastMessagePreview, c.lastActiveAt.timeIntervalSince1970, c.unreadCount]
        )
    }

    public func allConversations() async -> [Conversation] {
        do {
            return try await dbQueue.read { db in
                try Conversation.fetchAll(db, sql: "SELECT * FROM conversations ORDER BY lastActiveAt DESC")
            }
        } catch {
            Log.error("allConversations failed: \(error)")
            return []
        }
    }

    public func renameConversation(id: String, title: String) async {
        do {
            try await dbQueue.write { db in
                try db.execute(sql: "UPDATE conversations SET title = ? WHERE id = ?", arguments: [title, id])
            }
        } catch {
            Log.error("renameConversation failed: \(error)")
        }
    }

    public func deleteConversation(id: String) async {
        do {
            try await dbQueue.write { db in
                try db.execute(sql: "DELETE FROM messages WHERE conversationId = ?", arguments: [id])
                try db.execute(sql: "DELETE FROM conversations WHERE id = ?", arguments: [id])
            }
        } catch {
            Log.error("deleteConversation failed: \(error)")
        }
    }

    public func searchConversations(query: String) async -> [Conversation] {
        let q = query.lowercased()
        guard !q.isEmpty else { return await allConversations() }
        do {
            return try await dbQueue.read { db in
                try Conversation.fetchAll(db, sql: """
                    SELECT * FROM conversations
                    WHERE LOWER(title) LIKE ?
                       OR LOWER(peer_json) LIKE ?
                    ORDER BY lastActiveAt DESC
                    """, arguments: ["%\(q)%", "%\(q)%"])
            }
        } catch {
            Log.error("searchConversations failed: \(error)")
            return []
        }
    }

    // MARK: - Messages

    @discardableResult
    public func saveMessage(_ message: ChatMessage) async -> Bool {
        do {
            return try await dbQueue.write { db in
                try Self.saveMessage(db, message)
            }
        } catch {
            Log.error("saveMessage failed: \(error)")
            return false
        }
    }

    private static func saveMessage(_ db: Database, _ message: ChatMessage) throws -> Bool {
        var messageToSave = message
        var isNew = true

        // First preserve an existing local UUID for the same stable message
        // identity. Roster pagination and the live receive stream can deliver
        // one Signal message with different generated UUIDs.
        if let storeTs = message.storeTs {
            let candidates = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM messages
                WHERE conversationId = ? AND storeTs = ?
                  AND direction = ?
                """,
                arguments: [message.conversationId, storeTs, message.direction.rawValue]
            )
            for row in candidates {
                guard let id = UUID(uuidString: row["id"]) else { continue }
                let authorJSON: String = row["author_json"]
                guard let authorData = authorJSON.data(using: .utf8),
                      let author = try? JSONDecoder().decode(SignalAddress.self, from: authorData) else {
                    continue
                }
                let existingBody: String = row["body"]
                let existingAttachmentsJSON: String = row["attachments_json"]
                let existingBodyValue = Self.logicalBody(
                    existingBody,
                    attachmentsJSON: existingAttachmentsJSON
                )
                let messageBodyValue = Self.logicalBody(
                    message.body,
                    attachmentsJSON: String(
                        data: (try? JSONEncoder().encode(message.attachments)) ?? Data("[]".utf8),
                        encoding: .utf8
                    ) ?? "[]"
                )
                guard existingBodyValue == messageBodyValue else { continue }
                let sameAuthor = author.uuidString == message.author.uuidString
                    || (message.direction == .outgoing
                        && (author.uuidString == "self" || message.author.uuidString == "self"))
                if sameAuthor {
                    messageToSave.id = id
                    isNew = false
                    break
                }
            }
        }

        if isNew {
            let existingIDCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM messages WHERE id = ?",
                arguments: [message.id.uuidString]
            ) ?? 0
            isNew = existingIDCount == 0
        }

        let authorData = try JSONEncoder().encode(messageToSave.author)
        let authorJSON = String(data: authorData, encoding: .utf8)!
        let attachmentsData = try JSONEncoder().encode(messageToSave.attachments)
        let attachmentsJSON = String(data: attachmentsData, encoding: .utf8)!
        let reactionsData = try JSONEncoder().encode(messageToSave.reactions)
        let reactionsJSON = String(data: reactionsData, encoding: .utf8)!
        let readByData = try JSONEncoder().encode(messageToSave.readBy)
        let readByJSON = String(data: readByData, encoding: .utf8)!
        let deliveredToData = try JSONEncoder().encode(messageToSave.deliveredTo)
        let deliveredToJSON = String(data: deliveredToData, encoding: .utf8)!

        try db.execute(
            sql: """
            INSERT INTO messages (id, conversationId, author_json, body, direction, status, sentAt, attachments_json, storeTs, reactions_json, readBy_json, deliveredTo_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                conversationId = excluded.conversationId,
                author_json = excluded.author_json,
                body = excluded.body,
                direction = excluded.direction,
                status = excluded.status,
                sentAt = excluded.sentAt,
                attachments_json = excluded.attachments_json,
                storeTs = excluded.storeTs,
                reactions_json = excluded.reactions_json,
                readBy_json = excluded.readBy_json,
                deliveredTo_json = excluded.deliveredTo_json
            """,
            arguments: [
                messageToSave.id.uuidString,
                messageToSave.conversationId,
                authorJSON,
                messageToSave.body,
                messageToSave.direction.rawValue,
                messageToSave.status.rawValue,
                messageToSave.sentAt.timeIntervalSince1970,
                attachmentsJSON,
                messageToSave.storeTs,
                reactionsJSON,
                readByJSON,
                deliveredToJSON
            ]
        )

        // Bump conversation lastActiveAt / preview / unread only for a new
        // message. Replays must not inflate unread counts.
        let preview = String(messageToSave.body.prefix(120))
        let lastActive = messageToSave.sentAt.timeIntervalSince1970
        let unreadDelta = isNew && messageToSave.direction == .incoming ? 1 : 0
        try db.execute(sql: """
            INSERT INTO conversations (id, title, peer_json, lastMessagePreview, lastActiveAt, unreadCount)
            VALUES (?, '', '{}', ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                lastMessagePreview = excluded.lastMessagePreview,
                lastActiveAt = MAX(lastActiveAt, excluded.lastActiveAt),
                unreadCount = unreadCount + excluded.unreadCount
            """,
            arguments: [messageToSave.conversationId, preview, lastActive, unreadDelta]
        )
        return isNew
    }

    public func markRead(conversationId: String) async {
        do {
            try await dbQueue.write { db in
                try db.execute(sql: "UPDATE conversations SET unreadCount = 0 WHERE id = ?", arguments: [conversationId])
            }
        } catch {
            Log.error("markRead failed: \(error)")
        }
    }

    public func messages(in conversationId: String, limit: Int = 200) async -> [ChatMessage] {
        do {
            return try await dbQueue.read { db in
                try ChatMessage.fetchAll(db, sql: """
                    SELECT * FROM messages
                    WHERE conversationId = ?
                    ORDER BY sentAt ASC
                    LIMIT ?
                    """, arguments: [conversationId, limit])
            }
        } catch {
            Log.error("messages failed: \(error)")
            return []
        }
    }

    public func messages(in conversationId: String) async -> [ChatMessage] {
        await messages(in: conversationId, limit: 200)
    }

    public func messageCount(in conversationId: String) async -> Int {
        do {
            return try await dbQueue.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages WHERE conversationId = ?", arguments: [conversationId]) ?? 0
            }
        } catch {
            Log.error("messageCount failed: \(error)")
            return 0
        }
    }

    public func message(id: UUID) async -> ChatMessage? {
        do {
            return try await dbQueue.read { db in
                try ChatMessage.fetchOne(db, sql: "SELECT * FROM messages WHERE id = ?", arguments: [id.uuidString])
            }
        } catch {
            Log.error("message failed: \(error)")
            return nil
        }
    }

    public func updateMessage(id: UUID, transform: @escaping @Sendable (inout ChatMessage) -> Void) async -> Bool {
        do {
            return try await dbQueue.write { db in
                guard var msg = try ChatMessage.fetchOne(db, sql: "SELECT * FROM messages WHERE id = ?", arguments: [id.uuidString]) else {
                    return false
                }
                transform(&msg)
                _ = try Self.saveMessage(db, msg)
                return true
            }
        } catch {
            Log.error("updateMessage failed: \(error)")
            return false
        }
    }

    public func deleteMessage(id: UUID) async -> ChatMessage? {
        do {
            return try await dbQueue.write { db in
                guard let msg = try ChatMessage.fetchOne(db, sql: "SELECT * FROM messages WHERE id = ?", arguments: [id.uuidString]) else {
                    return nil
                }
                try db.execute(sql: "DELETE FROM messages WHERE id = ?", arguments: [id.uuidString])
                return msg
            }
        } catch {
            Log.error("deleteMessage failed: \(error)")
            return nil
        }
    }

    private static func logicalBody(_ body: String, attachmentsJSON: String) -> String {
        let hasAttachments = (try? JSONDecoder().decode([AttachmentMeta].self, from: Data(attachmentsJSON.utf8)))?.isEmpty == false
        if body == "[attachment]" && hasAttachments {
            return ""
        }
        return body
    }

    private static func isPlaceholderTitle(_ title: String) -> Bool {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty
            || value == "Unknown"
            || value.hasPrefix("+")
            || value.count == 8
            || UUID(uuidString: value) != nil
    }

    public func totalMessageCount() async -> Int {
        do {
            return try await dbQueue.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages") ?? 0
            }
        } catch {
            Log.error("totalMessageCount failed: \(error)")
            return 0
        }
    }

    public func clearAllData() async {
        do {
            try await dbQueue.write { db in
                try db.execute(sql: "DELETE FROM messages")
                try db.execute(sql: "DELETE FROM conversations")
            }
            Log.info("SQLiteMessageStore: cleared all data")
        } catch {
            Log.error("clearAllData failed: \(error)")
        }
    }
}

// MARK: - GRDB Record Conformance

extension Conversation: FetchableRecord {
    public init(row: Row) {
        id = row["id"]
        title = row["title"]
        let peerJSON: String = row["peer_json"]
        peer = (try? JSONDecoder().decode(SignalAddress.self, from: Data(peerJSON.utf8))) ?? SignalAddress()
        lastMessagePreview = row["lastMessagePreview"]
        lastActiveAt = Date(timeIntervalSince1970: row["lastActiveAt"])
        unreadCount = row["unreadCount"]
    }
}

extension ChatMessage: FetchableRecord {
    public init(row: Row) {
        id = UUID(uuidString: row["id"]) ?? UUID()
        conversationId = row["conversationId"]
        let authorJSON: String = row["author_json"]
        author = (try? JSONDecoder().decode(SignalAddress.self, from: Data(authorJSON.utf8))) ?? SignalAddress()
        body = row["body"]
        direction = MessageDirection(rawValue: row["direction"]) ?? .incoming
        status = MessageStatus(rawValue: row["status"]) ?? .queued
        sentAt = Date(timeIntervalSince1970: row["sentAt"])
        let attachmentsJSON: String = row["attachments_json"]
        attachments = (try? JSONDecoder().decode([AttachmentMeta].self, from: Data(attachmentsJSON.utf8))) ?? []
        storeTs = row["storeTs"]
        let reactionsJSON: String = row["reactions_json"]
        reactions = (try? JSONDecoder().decode([String].self, from: Data(reactionsJSON.utf8))) ?? []
        let readByJSON: String = row["readBy_json"]
        readBy = (try? JSONDecoder().decode([String].self, from: Data(readByJSON.utf8))) ?? []
        let deliveredToJSON: String = row["deliveredTo_json"]
        deliveredTo = (try? JSONDecoder().decode([String].self, from: Data(deliveredToJSON.utf8))) ?? []
    }
}
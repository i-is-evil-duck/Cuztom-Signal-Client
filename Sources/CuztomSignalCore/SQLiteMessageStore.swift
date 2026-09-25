import Foundation
import GRDB

/// SQLCipher-encrypted SQLite-backed MessageStore using GRDB. Implements
/// `MessageStoring`
/// so it can replace `InMemoryMessageStore` without touching the controller.
///
/// Schema:
/// - conversations: id (PK), title, peer_json, lastMessagePreview, lastActiveAt, unreadCount
/// - messages: id (PK), conversationId (FK), author_json, body, direction, status,
///             sentAt, attachments_json, reply_json, storeTs, reactions_json,
///             readBy_json, deliveredTo_json
///
/// Indexes on messages(conversationId, sentAt) for paging.
public actor SQLiteMessageStore: MessageStoring {
    private let dbQueue: DatabaseQueue
    private let path: URL
    private let keychainAccount: String?

    /// Create the presentation store. Production callers should omit
    /// `passphrase`; the value is loaded/created in the device-only Keychain.
    /// An explicit passphrase is intended for isolated tests and migration
    /// tooling.
    public init(path: URL? = nil, passphrase: String? = nil) throws {
        let base: URL
        if let path = path {
            base = path
        } else {
            base = try FileManager.default
                .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("CuztomSignal", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: base.path
        )
        let dbPath = base.appendingPathComponent("messages.sqlite")
        let canonicalPassphrase = try PresentationDatabaseSecurity.prepareDatabase(
            at: dbPath,
            explicitPassphrase: passphrase
        )
        self.path = dbPath
        self.keychainAccount = passphrase == nil
            ? PresentationDatabaseSecurity.keychainAccount(for: dbPath)
            : nil
        self.dbQueue = try DatabaseQueue(
            path: dbPath.path,
            configuration: PresentationDatabaseSecurity.configuration(passphrase: canonicalPassphrase)
        )
        try dbQueue.write { db in
            try Self.migrate(db)
        }
        Self.protectFile(at: dbPath)
        Self.protectFile(at: URL(fileURLWithPath: dbPath.path + "-wal"))
        Self.protectFile(at: URL(fileURLWithPath: dbPath.path + "-shm"))
    }

    private static func protectFile(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
    }

    private func removeIfPresent(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
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
            t.column("reply_json", .text)
            t.column("storeTs", .integer)
            t.column("reactions_json", .text).notNull()
            t.column("readBy_json", .text).notNull()
            t.column("deliveredTo_json", .text).notNull()
        }
        try db.create(index: "idx_messages_conversation_sentAt", on: "messages", columns: ["conversationId", "sentAt"], ifNotExists: true)
        try db.create(index: "idx_messages_conversation_storeTs", on: "messages", columns: ["conversationId", "storeTs"], ifNotExists: true)
        let hasReplyJSON = try db.columns(in: "messages").contains(where: { $0.name == "reply_json" })
        if !hasReplyJSON {
            try db.alter(table: "messages") { table in
                table.add(column: "reply_json", .text)
            }
        }
        // Reaction, delete, and other control envelopes can be stored as
        // empty DataMessages by older roster builders. They are not chat
        // messages and must not acquire a sender chip in the UI.
        try db.execute(sql: """
            DELETE FROM messages
            WHERE storeTs IS NOT NULL
              AND body = ''
              AND COALESCE(json_array_length(attachments_json), 0) = 0
              AND COALESCE(reply_json, '') = ''
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
        let oldState = try Row.fetchOne(
            db,
            sql: "SELECT lastMessagePreview, lastActiveAt, unreadCount FROM conversations WHERE id = ?",
            arguments: [c.id]
        )
        if let oldState {
            let oldPreview: String? = oldState["lastMessagePreview"]
            let oldActiveAt: Double = oldState["lastActiveAt"]
            let oldUnread: Int = oldState["unreadCount"]
            let hasNewerActivity = c.lastActiveAt.timeIntervalSince1970 > oldActiveAt
            c.unreadCount = max(c.unreadCount, oldUnread)
            if c.lastMessagePreview == nil || !hasNewerActivity {
                c.lastMessagePreview = oldPreview
            }
            if !hasNewerActivity {
                c.lastActiveAt = Date(timeIntervalSince1970: oldActiveAt)
            }
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
        await saveMessage(message, countsAsUnread: true)
    }

    @discardableResult
    public func saveMessage(_ message: ChatMessage, countsAsUnread: Bool) async -> Bool {
        do {
            return try await dbQueue.write { db in
                try Self.saveMessage(db, message, countsAsUnread: countsAsUnread)
            }
        } catch {
            Log.error("saveMessage failed: \(error)")
            return false
        }
    }

    private static func saveMessage(
        _ db: Database,
        _ message: ChatMessage,
        countsAsUnread: Bool = true
    ) throws -> Bool {
        var messageToSave = message
        var isNew = true

        // First preserve an existing local UUID for the same stable message
        // identity. Roster pagination and the live receive stream can deliver
        // one Signal message with different generated UUIDs.
        if let storeTs = message.storeTs, storeTs > 0 {
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
                let sameAuthor = author.uuidString == message.author.uuidString
                    || (message.direction == .outgoing
                        && (author.uuidString == "self" || message.author.uuidString == "self"))
                if sameAuthor {
                    let existing = ChatMessage(row: row)
                    messageToSave = Self.merge(existing: existing, incoming: message)
                    messageToSave.id = id
                    isNew = false
                    break
                }
            }
        }

        if isNew {
            if let existing = try ChatMessage.fetchOne(
                db,
                sql: "SELECT * FROM messages WHERE id = ?",
                arguments: [message.id.uuidString]
            ) {
                messageToSave = Self.merge(existing: existing, incoming: message)
                messageToSave.id = message.id
                isNew = false
            }
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
        let replyJSON = try messageToSave.replyTo.map { try JSONEncoder().encode($0) }
            .flatMap { String(data: $0, encoding: .utf8) }

        try db.execute(
            sql: """
            INSERT INTO messages (id, conversationId, author_json, body, direction, status, sentAt, attachments_json, reply_json, storeTs, reactions_json, readBy_json, deliveredTo_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                conversationId = excluded.conversationId,
                author_json = excluded.author_json,
                body = excluded.body,
                direction = excluded.direction,
                status = excluded.status,
                sentAt = excluded.sentAt,
                attachments_json = excluded.attachments_json,
                reply_json = excluded.reply_json,
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
                replyJSON,
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
        let unreadDelta = isNew && countsAsUnread && messageToSave.direction == .incoming ? 1 : 0
        try db.execute(sql: """
            INSERT INTO conversations (id, title, peer_json, lastMessagePreview, lastActiveAt, unreadCount)
            VALUES (?, '', '{}', ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                lastMessagePreview = CASE
                    WHEN excluded.lastActiveAt >= lastActiveAt THEN excluded.lastMessagePreview
                    ELSE lastMessagePreview
                END,
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
                    SELECT * FROM (
                        SELECT * FROM messages
                        WHERE conversationId = ?
                        ORDER BY sentAt DESC, id DESC
                        LIMIT ?
                    ) AS newest_page
                    ORDER BY sentAt ASC, id ASC
                    """, arguments: [conversationId, max(0, limit)])
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

    public func message(conversationId: String, storeTs: Int64) async -> ChatMessage? {
        do {
            return try await dbQueue.read { db in
                try ChatMessage.fetchOne(
                    db,
                    sql: "SELECT * FROM messages WHERE conversationId = ? AND storeTs = ? ORDER BY sentAt DESC, id DESC LIMIT 1",
                    arguments: [conversationId, storeTs]
                )
            }
        } catch {
            Log.error("message(conversationId:storeTs:) failed: \(error)")
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
                try Self.deleteMessageRow(db, msg)
                return msg
            }
        } catch {
            Log.error("deleteMessage failed: \(error)")
            return nil
        }
    }

    public func deleteMessage(conversationId: String, storeTs: Int64) async -> ChatMessage? {
        do {
            return try await dbQueue.write { db in
                guard let msg = try ChatMessage.fetchOne(
                    db,
                    sql: "SELECT * FROM messages WHERE conversationId = ? AND storeTs = ? ORDER BY sentAt DESC, id DESC LIMIT 1",
                    arguments: [conversationId, storeTs]
                ) else {
                    return nil
                }
                try Self.deleteMessageRow(db, msg)
                return msg
            }
        } catch {
            Log.error("deleteMessage(conversationId:storeTs:) failed: \(error)")
            return nil
        }
    }

    private static func deleteMessageRow(_ db: Database, _ message: ChatMessage) throws {
        try db.execute(sql: "DELETE FROM messages WHERE id = ?", arguments: [message.id.uuidString])
        let unreadDelta = message.direction == .incoming ? 1 : 0
        try db.execute(
            sql: "UPDATE conversations SET unreadCount = MAX(0, unreadCount - ?) WHERE id = ?",
            arguments: [unreadDelta, message.conversationId]
        )
        if let remaining = try ChatMessage.fetchOne(
            db,
            sql: "SELECT * FROM messages WHERE conversationId = ? ORDER BY sentAt DESC, id DESC LIMIT 1",
            arguments: [message.conversationId]
        ) {
            let preview = String(remaining.body.prefix(120))
            let activeAt = remaining.sentAt.timeIntervalSince1970
            try db.execute(
                sql: "UPDATE conversations SET lastMessagePreview = ?, lastActiveAt = ? WHERE id = ?",
                arguments: [preview, activeAt, message.conversationId]
            )
        } else {
            try db.execute(
                sql: "UPDATE conversations SET lastMessagePreview = NULL, lastActiveAt = ? WHERE id = ?",
                arguments: [Date.distantPast.timeIntervalSince1970, message.conversationId]
            )
        }
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
            for index in merged.attachments.indices
                where merged.attachments[index].localURL == nil
                    && index < existing.attachments.count {
                merged.attachments[index].localURL = existing.attachments[index].localURL
            }
        }
        return merged
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
            try await clearAllDataChecked()
            Log.info("SQLiteMessageStore: cleared all data")
        } catch {
            Log.error("clearAllData failed: \(error)")
        }
    }

    public func clearAllDataChecked() async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM messages")
            try db.execute(sql: "DELETE FROM conversations")
        }
        // Keep the open GRDB queue, but reclaim pages and verify that the
        // presentation tables are empty before logout reports success.
        try await dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM")
            let messages = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages") ?? 0
            let conversations = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM conversations") ?? 0
            guard messages == 0, conversations == 0 else {
                throw SignalError.storage("presentation store wipe verification failed")
            }
        }
        // Keep the encrypted queue alive for callers that inspect the store
        // after a routine wipe. The authoritative logout path uses destroy()
        // below when it can safely close the connection first.
    }

    /// Terminal presentation-store wipe used by authoritative logout. The
    /// actor is not reusable after this method succeeds.
    public func destroy() async throws {
        try await clearAllDataChecked()
        try dbQueue.close()
        try removeIfPresent(path)
        try removeIfPresent(URL(fileURLWithPath: path.path + "-wal"))
        try removeIfPresent(URL(fileURLWithPath: path.path + "-shm"))
        try removeIfPresent(URL(fileURLWithPath: path.path + "-journal"))
        if let keychainAccount {
            try PresentationDatabaseSecurity.deleteKey(account: keychainAccount)
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
        let replyJSON: String? = row["reply_json"]
        replyTo = replyJSON.flatMap { try? JSONDecoder().decode(MessageReference.self, from: Data($0.utf8)) }
        storeTs = row["storeTs"]
        let reactionsJSON: String = row["reactions_json"]
        reactions = (try? JSONDecoder().decode([String].self, from: Data(reactionsJSON.utf8))) ?? []
        let readByJSON: String = row["readBy_json"]
        readBy = (try? JSONDecoder().decode([String].self, from: Data(readByJSON.utf8))) ?? []
        let deliveredToJSON: String = row["deliveredTo_json"]
        deliveredTo = (try? JSONDecoder().decode([String].self, from: Data(deliveredToJSON.utf8))) ?? []
    }
}
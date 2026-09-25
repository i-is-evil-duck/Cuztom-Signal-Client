import Foundation
import GRDB
import Testing
@testable import CuztomSignalCore

@Test func addressDisplayKeyPrefersGroup() {
    let addr = SignalAddress(uuidString: "u", phone: "+1", groupId: "group.abc")
    #expect(addr.isGroup)
    #expect(addr.displayKey == "group.abc")
}

@Test func messageDefaultsToQueued() {
    let msg = ChatMessage(
        conversationId: "c1",
        author: SignalAddress(uuidString: "peer"),
        body: "hello",
        direction: .incoming
    )
    #expect(msg.status == .queued)
    #expect(msg.attachments.isEmpty)
}

@Test func storeOrdersConversationsByRecency() async {
    let store = MessageStore()
    let old = Conversation(id: "old", title: "Old", peer: SignalAddress(phone: "+1"),
                           lastActiveAt: Date(timeIntervalSince1970: 100))
    let new = Conversation(id: "new", title: "New", peer: SignalAddress(phone: "+2"),
                           lastActiveAt: Date(timeIntervalSince1970: 200))
    await store.upsertConversation(old)
    await store.upsertConversation(new)
    let all = await store.allConversations()
    #expect(all.first?.id == "new")
}

@Test func storeBumpsUnreadOnIncoming() async {
    let store = MessageStore()
    let conv = Conversation(id: "c1", title: "Peer", peer: SignalAddress(phone: "+1"))
    await store.upsertConversation(conv)
    await store.saveMessage(ChatMessage(conversationId: "c1",
                                        author: SignalAddress(phone: "+1"),
                                        body: "hi",
                                        direction: .incoming))
    let all = await store.allConversations()
    #expect(all.first?.unreadCount == 1)
    #expect(all.first?.lastMessagePreview == "hi")
    await store.markRead(conversationId: "c1")
    let after = await store.allConversations()
    #expect(after.first?.unreadCount == 0)
}

@Test func mockServiceRequiresLink() async {
    let svc = MockSignalService()
    do {
        _ = try await svc.fetchConversations()
        Issue.record("expected notLinked")
    } catch SignalError.notLinked {
        // expected
    } catch {
        Issue.record("wrong error: \(error)")
    }
}

@Test func mockServiceLinksAndSends() async throws {
    let conv = Conversation(id: "c1", title: "Peer", peer: SignalAddress(phone: "+1"))
    let svc = MockSignalService(seedConversations: [conv])
    _ = try await svc.beginLinking(deviceName: "TestMac")
    try await svc.waitForLink()
    let convs = try await svc.fetchConversations()
    #expect(convs.count == 1)
    let sent = try await svc.sendText("hello", to: "c1")
    #expect(sent.status == .sent)
    #expect(sent.direction == .outgoing)
    let history = try await svc.fetchMessages(conversationId: "c1", limit: 10)
    #expect(history.count == 1)
}

@Test func secretStoreRoundTrips() async throws {
    let store = InMemorySecretStore()
    try await store.save(key: "identity", value: Data("secret".utf8))
    let loaded = await store.load(key: "identity")
    #expect(loaded == Data("secret".utf8))
    await store.delete(key: "identity")
    #expect(await store.load(key: "identity") == nil)
}

@Test func sqliteStoreRoundTrips() async throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("sqlite-test-\(UUID())")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }
    
    let store = try SQLiteMessageStore(path: tmpDir)
    
    let conv = Conversation(id: "c1", title: "Peer", peer: SignalAddress(phone: "+1"),
                            lastActiveAt: Date(timeIntervalSince1970: 100))
    await store.upsertConversation(conv)
    let all = await store.allConversations()
    #expect(all.count == 1)
    #expect(all.first?.title == "Peer")
    
    let msg = ChatMessage(conversationId: "c1",
                          author: SignalAddress(phone: "+1"),
                          body: "hi",
                          direction: .incoming,
                          status: .delivered)
    await store.saveMessage(msg)
    let msgs = await store.messages(in: "c1")
    #expect(msgs.count == 1)
    #expect(msgs.first?.body == "hi")
    
    let unread = await store.allConversations()
    #expect(unread.first?.unreadCount == 1)
    await store.markRead(conversationId: "c1")
    let read = await store.allConversations()
    #expect(read.first?.unreadCount == 0)
    
    // Persistence: reopen and verify
    let store2 = try SQLiteMessageStore(path: tmpDir)
    let reloaded = await store2.allConversations()
    #expect(reloaded.count == 1)
    #expect(reloaded.first?.title == "Peer")
    let reloadedMsgs = await store2.messages(in: "c1")
    #expect(reloadedMsgs.count == 1)
    #expect(reloadedMsgs.first?.body == "hi")
}

@Test func sqliteStoreMigratesPlaintextAndRejectsWrongKey() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("sqlite-encryption-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let dbURL = directory.appendingPathComponent("messages.sqlite")

    let plaintext = try DatabaseQueue(path: dbURL.path)
    try await plaintext.write { db in
        try db.create(table: "conversations") { table in
            table.column("id", .text).primaryKey()
            table.column("title", .text).notNull()
            table.column("peer_json", .text).notNull()
            table.column("lastMessagePreview", .text)
            table.column("lastActiveAt", .double).notNull()
            table.column("unreadCount", .integer).notNull().defaults(to: 0)
        }
        try db.create(table: "messages") { table in
            table.column("id", .text).primaryKey()
            table.column("conversationId", .text).notNull()
            table.column("author_json", .text).notNull()
            table.column("body", .text).notNull()
            table.column("direction", .text).notNull()
            table.column("status", .text).notNull()
            table.column("sentAt", .double).notNull()
            table.column("attachments_json", .text).notNull()
            table.column("reply_json", .text)
            table.column("storeTs", .integer)
            table.column("reactions_json", .text).notNull()
            table.column("readBy_json", .text).notNull()
            table.column("deliveredTo_json", .text).notNull()
        }
        try db.execute(sql: "INSERT INTO conversations VALUES ('c1', 'Peer', '{}', NULL, 1, 0)")
    }
    try plaintext.close()

    _ = try SQLiteMessageStore(path: directory, passphrase: "correct-key")
    let header = try Data(contentsOf: dbURL).prefix(16)
    #expect(Data(header) != Data([0x53, 0x51, 0x4C, 0x69, 0x74, 0x65, 0x20, 0x66, 0x6F, 0x72, 0x6D, 0x61, 0x74, 0x20, 0x33, 0x00]))

    let encryptedReader = try DatabaseQueue(
        path: dbURL.path,
        configuration: PresentationDatabaseSecurity.configuration(passphrase: "correct-key")
    )
    let cipherVersion = try await encryptedReader.read { db in
        try String.fetchOne(db, sql: "PRAGMA cipher_version")
    }
    #expect(cipherVersion?.isEmpty == false)
    try encryptedReader.close()

    let reopened = try SQLiteMessageStore(path: directory, passphrase: "correct-key")
    let reopenedConversations = await reopened.allConversations()
    #expect(reopenedConversations.count == 1)
    do {
        _ = try SQLiteMessageStore(path: directory, passphrase: "wrong-key")
        Issue.record("expected wrong presentation passphrase to fail")
    } catch {
        // Expected: SQLCipher refuses the file rather than falling back.
    }
}

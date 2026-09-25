import Foundation
import Testing
@testable import CuztomSignalCore

private let rosterFixture = """
{"self":{"aci":"00000000-0000-0000-0000-000000000000","number":"+1000"},
 "contacts":[{"id":"11111111-1111-1111-1111-111111111111","name":"Alice","phone":"+1001"},
             {"id":"22222222-2222-2222-2222-222222222222","name":"","phone":"+1002"}],
 "groups":[{"id":"ab12","title":"Reels"}],
 "messages":[
  {"key":"contact:11111111-1111-1111-1111-111111111111/1000/11111111-1111-1111-1111-111111111111",
   "thread":"contact:11111111-1111-1111-1111-111111111111",
   "sender":"11111111-1111-1111-1111-111111111111","sender_name":"Alice",
   "body":"hey","ts":1000,"outgoing":false},
  {"key":"group:ab12/2000/self","thread":"group:ab12",
   "sender":"self","sender_name":"You","body":"yo","ts":2000,"outgoing":true}]}
"""

@Test func rosterMapsToConversations() throws {
    let svc = RustCoreService(libraryPath: "/nonexistent/lib.dylib")
    let payload = try JSONDecoder().decode(RosterPayload.self, from: Data(rosterFixture.utf8))
    let convs = svc.applyRoster(payload)
    #expect(convs.count == 3)
    #expect(convs[0].id == "group:ab12") // newest first
    #expect(convs[0].title == "Reels")
    #expect(convs[0].peer.isGroup)
    #expect(convs[1].title == "Alice")
    #expect(convs[1].lastMessagePreview == "hey")
    #expect(convs[2].title == "+1002") // unnamed contact falls back to phone
    #expect(convs[2].lastMessagePreview == nil)
}

@Test func rosterMessageIdsAreStable() throws {
    let svc = RustCoreService(libraryPath: "/nonexistent/lib.dylib")
    let payload = try JSONDecoder().decode(RosterPayload.self, from: Data(rosterFixture.utf8))
    _ = svc.applyRoster(payload)
    let first = svc.chatMessage(payload.messages[0])
    _ = svc.applyRoster(payload) // refresh must not duplicate
    let second = svc.chatMessage(payload.messages[0])
    #expect(first.id == second.id)
    #expect(first.direction == .incoming)
    #expect(first.status == .delivered)
    let sent = svc.chatMessage(payload.messages[1])
    #expect(sent.direction == .outgoing)
    #expect(sent.conversationId == "group:ab12")
}

@Test func liveEventDecodes() throws {
    let json = """
    {"type":"message","message":{\
    "key":"k","thread":"contact:x","sender":"x","sender_name":"X",\
    "body":"hi","ts":5,"outgoing":false}}
    """
    let event = try JSONDecoder().decode(LiveEvent.self, from: Data(json.utf8))
    #expect(event.type == "message")
    #expect(event.message?.body == "hi")
}

@Test func replyReferenceMapsFromRoster() throws {
    let json = """
    {"self":{"aci":"a","number":"+1"},"contacts":[],"groups":[],"messages":[{
      "key":"k","thread":"contact:x","sender":"x","sender_name":"X",
      "body":"reply","ts":10,"sts":20,"outgoing":false,
      "reply_to":{"target_sts":9,"author":"y","body":"original"}
    }]}
    """
    let payload = try JSONDecoder().decode(RosterPayload.self, from: Data(json.utf8))
    let svc = RustCoreService(libraryPath: "/nonexistent/lib.dylib")
    let message = svc.chatMessage(payload.messages[0])
    #expect(message.replyTo?.storeTs == 9)
    #expect(message.replyTo?.authorID == "y")
    #expect(message.replyTo?.body == "original")
}

@Test func reactionSummaryMapsFromRoster() throws {
    let json = """
    {"self":{"aci":"a","number":"+1"},"contacts":[],"groups":[],"messages":[{
      "key":"k","thread":"contact:x","sender":"x","sender_name":"X",
      "body":"reacted","ts":10,"sts":20,"outgoing":false,
      "reactions":["👍","👍","❤️"]
    }]}
    """
    let payload = try JSONDecoder().decode(RosterPayload.self, from: Data(json.utf8))
    let message = RustCoreService(libraryPath: "/nonexistent/lib.dylib")
        .chatMessage(payload.messages[0])
    #expect(message.reactions == ["👍", "👍", "❤️"])
}

@Test func manualAttachmentPathPersistsAcrossServiceInstances() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("cuztom-path-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("downloaded.jpg")
    try Data([0x01, 0x02]).write(to: file)

    let first = RustCoreService(libraryPath: "/nonexistent/lib.dylib")
    first.bindLocalPath(thread: "contact:x", ts: 42, index: 0, path: file.path)

    let json = """
    {"self":{"aci":"a","number":"+1"},"contacts":[],"groups":[],"messages":[{
      "key":"contact:x/42/x","thread":"contact:x","sender":"x","sender_name":"X",
      "body":"file","ts":41,"sts":42,"outgoing":false,
      "attachments":[{"name":"downloaded.jpg","mime":"image/jpeg","size":2,"path":null}]
    }]}
    """
    let payload = try JSONDecoder().decode(RosterPayload.self, from: Data(json.utf8))
    let second = RustCoreService(libraryPath: "/nonexistent/lib.dylib")
    let message = second.chatMessage(payload.messages[0])
    #expect(message.attachments.first?.localURL?.path == file.path)
}

@Test func attachmentMetadataMaps() throws {
    // chatMessage only links paths that exist on disk (stale cache prune).
    let real = FileManager.default.temporaryDirectory.appendingPathComponent("cuztom-test-photo.jpg")
    try "x".write(to: real, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: real) }
    let json = """
    {"self":{"aci":"a","number":"+1"},"contacts":[],"groups":[],
     "messages":[{
      "key":"k","thread":"contact:x","sender":"x","sender_name":"X",
      "body":"","ts":9,"outgoing":false,
      "attachments":[
        {"name":"photo.jpg","mime":"image/jpeg","size":123,"path":"\(real.path)"},
        {"name":"big.mov","mime":"video/quicktime","size":999,"path":null}]}]}
    """
    let svc = RustCoreService(libraryPath: "/nonexistent/lib.dylib")
    let payload = try JSONDecoder().decode(RosterPayload.self, from: Data(json.utf8))
    let msg = svc.chatMessage(payload.messages[0])
    #expect(msg.attachments.count == 2)
    #expect(msg.attachments[0].localURL?.path == real.path)
    #expect(msg.attachments[1].localURL == nil)
    #expect(msg.body == "[attachment]")
}

@Test func duplicateReplayIsIdempotent() async {
    let store = MessageStore()
    let conversation = Conversation(
        id: "contact:11111111-1111-1111-1111-111111111111",
        title: "Alice",
        peer: SignalAddress(uuidString: "11111111-1111-1111-1111-111111111111")
    )
    await store.upsertConversation(conversation)
    let first = ChatMessage(
        id: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
        conversationId: conversation.id,
        author: SignalAddress(uuidString: "11111111-1111-1111-1111-111111111111"),
        body: "same message",
        direction: .incoming,
        sentAt: Date(timeIntervalSince1970: 1),
        storeTs: 1234
    )
    let replay = ChatMessage(
        id: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!,
        conversationId: conversation.id,
        author: first.author,
        body: first.body,
        direction: first.direction,
        sentAt: first.sentAt,
        storeTs: first.storeTs
    )
    #expect(await store.saveMessage(first))
    #expect(!(await store.saveMessage(replay)))
    #expect(await store.messageCount(in: conversation.id) == 1)
    #expect(await store.allConversations().first?.unreadCount == 1)
}

@Test func attachmentPlaceholderReplayIsIdempotent() async {
    let store = MessageStore()
    let conversation = Conversation(
        id: "contact:33333333-3333-3333-3333-333333333333",
        title: "Media",
        peer: SignalAddress(uuidString: "33333333-3333-3333-3333-333333333333")
    )
    await store.upsertConversation(conversation)
    let attachment = AttachmentMeta(filename: "clip.gif", mimeType: "image/gif", byteCount: 10)
    let empty = ChatMessage(
        id: UUID(uuidString: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")!,
        conversationId: conversation.id,
        author: SignalAddress(uuidString: "33333333-3333-3333-3333-333333333333"),
        body: "",
        direction: .incoming,
        sentAt: Date(timeIntervalSince1970: 3),
        attachments: [attachment],
        storeTs: 9999
    )
    let placeholder = ChatMessage(
        id: UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!,
        conversationId: conversation.id,
        author: empty.author,
        body: "[attachment]",
        direction: .incoming,
        sentAt: empty.sentAt,
        attachments: [attachment],
        storeTs: empty.storeTs
    )
    #expect(await store.saveMessage(empty))
    #expect(!(await store.saveMessage(placeholder)))
    #expect(await store.messageCount(in: conversation.id) == 1)
}

@Test func sqliteDeduplicatesDifferentLocalUUIDs() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("cuztom-duplicate-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try SQLiteMessageStore(path: directory)
    let conversation = Conversation(
        id: "contact:22222222-2222-2222-2222-222222222222",
        title: "Bob",
        peer: SignalAddress(uuidString: "22222222-2222-2222-2222-222222222222")
    )
    await store.upsertConversation(conversation)
    let author = SignalAddress(uuidString: conversation.peer.uuidString!)
    let first = ChatMessage(
        id: UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!,
        conversationId: conversation.id,
        author: author,
        body: "one",
        direction: .incoming,
        sentAt: Date(timeIntervalSince1970: 2),
        storeTs: 4321
    )
    let second = ChatMessage(
        id: UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!,
        conversationId: conversation.id,
        author: author,
        body: "one",
        direction: .incoming,
        sentAt: first.sentAt,
        storeTs: first.storeTs
    )
    #expect(await store.saveMessage(first))
    #expect(!(await store.saveMessage(second)))
    #expect(await store.messageCount(in: conversation.id) == 1)
    #expect(await store.allConversations().first?.unreadCount == 1)
}

@Test func storeUpdatesMessageInPlace() async {
    let store = MessageStore()
    let msg = ChatMessage(conversationId: "c1", author: SignalAddress(phone: "+1"),
                          body: "hi", direction: .incoming)
    await store.saveMessage(msg)
    let found = await store.message(id: msg.id)
    #expect(found?.body == "hi")
    let ok = await store.updateMessage(id: msg.id) { $0.body = "edited" }
    #expect(ok)
    #expect(await store.message(id: msg.id)?.body == "edited")
    #expect(!(await store.updateMessage(id: UUID()) { $0.body = "x" }))
}

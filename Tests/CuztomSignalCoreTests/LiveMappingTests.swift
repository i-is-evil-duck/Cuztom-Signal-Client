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

@Test func attachmentMetadataMaps() throws {
    let json = """
    {"self":{"aci":"a","number":"+1"},"contacts":[],"groups":[],
     "messages":[{
      "key":"k","thread":"contact:x","sender":"x","sender_name":"X",
      "body":"","ts":9,"outgoing":false,
      "attachments":[
        {"name":"photo.jpg","mime":"image/jpeg","size":123,"path":"/tmp/photo.jpg"},
        {"name":"big.mov","mime":"video/quicktime","size":999,"path":null}]}]}
    """
    let svc = RustCoreService(libraryPath: "/nonexistent/lib.dylib")
    let payload = try JSONDecoder().decode(RosterPayload.self, from: Data(json.utf8))
    let msg = svc.chatMessage(payload.messages[0])
    #expect(msg.attachments.count == 2)
    #expect(msg.attachments[0].localURL?.path == "/tmp/photo.jpg")
    #expect(msg.attachments[1].localURL == nil)
    #expect(msg.body == "[attachment]")
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

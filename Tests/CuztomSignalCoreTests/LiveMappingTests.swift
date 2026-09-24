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

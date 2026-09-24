import Foundation
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

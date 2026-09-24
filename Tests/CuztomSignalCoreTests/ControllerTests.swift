import Foundation
import Testing
@testable import CuztomSignalCore

@Test func controllerFullFlow() async throws {
    let alice = Conversation(id: "c1", title: "Alice", peer: SignalAddress(phone: "+1001"))
    let group = Conversation(id: "group.abc", title: "Reels", peer: SignalAddress(groupId: "group.abc"))
    let seedMsg = ChatMessage(conversationId: "c1", author: SignalAddress(phone: "+1001"),
                              body: "hey", direction: .incoming, status: .delivered)
    let svc = MockSignalService(seedConversations: [alice, group], seedMessages: ["c1": [seedMsg]])
    let controller = await ChatController(service: svc)

    await controller.link(deviceName: "TestMac")
    let linked = await controller.isLinked
    #expect(linked)
    let convs = await controller.conversations
    #expect(convs.count == 2)

    await controller.select("c1")
    let initial = await controller.messages
    #expect(initial.count == 1)
    let selected = await controller.selectedId
    #expect(selected == "c1")

    await controller.send("hello back")
    let afterSend = await controller.messages
    #expect(afterSend.count == 2)
    #expect(afterSend.last?.direction == .outgoing)

    // Inbound on the open thread appears live.
    let inbound = ChatMessage(conversationId: "c1", author: SignalAddress(phone: "+1001"),
                              body: "nice", direction: .incoming)
    await controller.receive(inbound)
    let afterReceive = await controller.messages
    #expect(afterReceive.count == 3)
}

@Test func controllerSendWithoutSelectionIsNoOp() async {
    let svc = MockSignalService()
    let controller = await ChatController(service: svc)
    await controller.link()
    await controller.send("nowhere")
    let messages = await controller.messages
    #expect(messages.isEmpty)
    let err = await controller.lastError
    #expect(err == nil)
}

@Test func controllerSurfacesLinkFailure() async {
    struct Broken: SignalService, Sendable {
        var connectionState: AsyncStream<ConnectionState> { AsyncStream { _ in } }
        func beginLinking(deviceName: String) async throws -> LinkQR { throw SignalError.network("offline") }
        func waitForLink() async throws {}
        func fetchConversations() async throws -> [Conversation] { [] }
        func fetchMessages(conversationId: String, limit: Int) async throws -> [ChatMessage] { [] }
        func sendText(_ body: String, to conversationId: String) async throws -> ChatMessage {
            throw SignalError.notLinked
        }
        func incomingMessages() -> AsyncStream<ChatMessage> { AsyncStream { _ in } }
    }
    let controller = await ChatController(service: Broken())
    await controller.link()
    let linked = await controller.isLinked
    #expect(!linked)
    let err = await controller.lastError
    #expect(err != nil)
}

@Test func rustCoreWithoutLibraryThrowsUnsupported() async {
    let svc = RustCoreService(libraryPath: "/nonexistent/libcuztom_signal_core.dylib")
    #expect(!svc.isLibraryLoaded)
    do {
        _ = try await svc.beginLinking(deviceName: "TestMac")
        Issue.record("expected unsupported")
    } catch SignalError.unsupported {
        // expected seam behavior until M1 wires the Manager
    } catch {
        Issue.record("wrong error: \(error)")
    }
}

@Test func storeSearchDeleteAndTotals() async {
    let store = MessageStore()
    let a = Conversation(id: "c1", title: "Alice", peer: SignalAddress(phone: "+1001"))
    let b = Conversation(id: "group.abc", title: "Reels", peer: SignalAddress(groupId: "group.abc"))
    await store.upsertConversation(a)
    await store.upsertConversation(b)
    await store.saveMessage(ChatMessage(conversationId: "c1", author: SignalAddress(phone: "+1001"),
                                        body: "hi", direction: .incoming))
    await store.saveMessage(ChatMessage(conversationId: "group.abc", author: SignalAddress(phone: "+1002"),
                                        body: "reel", direction: .incoming))

    #expect(await store.totalMessageCount() == 2)
    #expect(await store.searchConversations(query: "alice").map(\.id) == ["c1"])
    #expect(await store.searchConversations(query: "group.").map(\.id) == ["group.abc"])
    #expect(await store.searchConversations(query: "").count == 2)

    await store.deleteConversation(id: "c1")
    #expect(await store.allConversations().count == 1)
    #expect(await store.totalMessageCount() == 1)
    #expect(await store.messageCount(in: "c1") == 0)
}

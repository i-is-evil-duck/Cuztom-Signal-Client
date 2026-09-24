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

@Test func controllerBeginFinishSplit() async throws {
    let conv = Conversation(id: "c1", title: "Peer", peer: SignalAddress(phone: "+1"))
    let svc = MockSignalService(seedConversations: [conv])
    let controller = await ChatController(service: svc)

    let begun = await controller.begin(deviceName: "TestMac")
    #expect(begun)
    let qr = await controller.linkQR
    #expect(qr != nil)
    let conn = await controller.connection
    #expect(conn == .linking)
    // Not linked yet: roster still empty before finish().
    #expect(await controller.isLinked == false)

    let done = await controller.finish()
    #expect(done)
    #expect(await controller.isLinked)
    #expect(await controller.conversations.count == 1)
}

@Test func controllerResumesExistingSession() async {
    struct AlreadyLive: SignalService, Sendable {
        var connectionState: AsyncStream<ConnectionState> { AsyncStream { _ in } }
        func beginLinking(deviceName: String) async throws -> LinkQR { throw SignalError.alreadyLinked }
        func waitForLink() async throws {}
        func fetchConversations() async throws -> [Conversation] {
            [Conversation(id: "c1", title: "Peer", peer: SignalAddress(phone: "+1"))]
        }
        func fetchMessages(conversationId: String, limit: Int) async throws -> [ChatMessage] { [] }
        func sendText(_ body: String, to conversationId: String) async throws -> ChatMessage {
            throw SignalError.notLinked
        }
        func incomingMessages() -> AsyncStream<ChatMessage> { AsyncStream { _ in } }
    }
    let controller = await ChatController(service: AlreadyLive())
    #expect(await controller.begin()) // no QR needed
    let qr = await controller.linkQR
    #expect(qr == nil)
    #expect(await controller.finish())
    #expect(await controller.isLinked)
    #expect(await controller.conversations.count == 1)
}

@Test func controllerLogoutResetsState() async throws {
    let conv = Conversation(id: "c1", title: "Peer", peer: SignalAddress(phone: "+1"))
    let svc = MockSignalService(seedConversations: [conv])
    let controller = await ChatController(service: svc)
    await controller.link(deviceName: "TestMac")
    #expect(await controller.isLinked)
    await controller.select("c1")
    #expect(await controller.logout())
    #expect(!(await controller.isLinked))
    #expect(await controller.conversations.isEmpty)
    #expect(await controller.selectedId == nil)
    let diag = await controller.diagnostics()
    #expect(diag.contains("mock"))
    #expect(diag.contains("conversations: 0"))
}

@Test func controllerRefreshNowReportsFailure() async {
    struct Broken: SignalService, Sendable {
        var connectionState: AsyncStream<ConnectionState> { AsyncStream { _ in } }
        func beginLinking(deviceName: String) async throws -> LinkQR { throw SignalError.network("offline") }
        func waitForLink() async throws {}
        func fetchConversations() async throws -> [Conversation] { throw SignalError.network("offline") }
        func fetchMessages(conversationId: String, limit: Int) async throws -> [ChatMessage] { [] }
        func sendText(_ body: String, to conversationId: String) async throws -> ChatMessage {
            throw SignalError.notLinked
        }
        func incomingMessages() -> AsyncStream<ChatMessage> { AsyncStream { _ in } }
    }
    let controller = await ChatController(service: Broken())
    #expect(!(await controller.refreshNow()))
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
        // expected seam behavior when no dylib is present
    } catch {
        Issue.record("wrong error: \(error)")
    }
}

@Test func rustCoreLocalBuildInitsFreshOffline() async throws {
    // Offline-safe: init only touches sqlite, never the network.
    // Skips cleanly on machines where rust-core/ was never built.
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("cuztom-swift-test-\(ProcessInfo.processInfo.processIdentifier)")
    let db = dir.appendingPathComponent("signal.db").path
    let svc = RustCoreService(dbPath: db)
    guard svc.loadLibrary() else { return }
    #expect(svc.isLibraryLoaded)
    let linked = try await svc.isLinkedAccount()
    #expect(!linked) // fresh temp store
    let again = try await svc.isLinkedAccount()
    #expect(!again) // init is idempotent
    try? FileManager.default.removeItem(at: dir)
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

@Test func storeDeletesSingleMessage() async {
    let store = MessageStore()
    let m1 = ChatMessage(conversationId: "c1", author: SignalAddress(phone: "+1"),
                         body: "one", direction: .incoming)
    let m2 = ChatMessage(conversationId: "c1", author: SignalAddress(phone: "+1"),
                         body: "two", direction: .incoming)
    await store.saveMessage(m1)
    await store.saveMessage(m2)
    let removed = await store.deleteMessage(id: m1.id)
    #expect(removed?.body == "one")
    #expect(await store.messageCount(in: "c1") == 1)
    #expect(await store.deleteMessage(id: UUID()) == nil)
}

@Test func controllerDeletesForMeWithMock() async {
    let conv = Conversation(id: "c1", title: "Peer", peer: SignalAddress(phone: "+1"))
    let svc = MockSignalService(seedConversations: [conv])
    let controller = await ChatController(service: svc)
    await controller.link()
    await controller.select("c1")
    await controller.send("bye")
    let id = await controller.messages.first?.id
    #expect(id != nil)
    // Mock has no live backend: for-me works locally, for-everyone refuses.
    #expect(await controller.deleteMessage(id: id!, forEveryone: false))
    #expect(await controller.messages.isEmpty)
    #expect(!(await controller.deleteMessage(id: UUID(), forEveryone: true)))
}

@Test func controllerAppliesReactionsAndReceipts() async {
    let conv = Conversation(id: "c1", title: "Peer", peer: SignalAddress(phone: "+1"))
    let svc = MockSignalService(seedConversations: [conv])
    let controller = await ChatController(service: svc)
    await controller.link()
    await controller.select("c1")
    await controller.send("hi")
    guard let sent = await controller.messages.first else {
        Issue.record("no sent message")
        return
    }
    // Reactions keyed by store timestamp (nil here -> server ms fallback path
    // uses sentAt; applyReaction matches storeTs first).
    await controller.applyReaction(thread: "c1", targetSts: sent.storeTs ?? 0, emoji: "👍", remove: false, senderName: "Peer")
    // storeTs is nil for mock echoes, so no match: seed one with explicit sts.
    let withSts = ChatMessage(conversationId: "c1", author: SignalAddress(phone: "+1"),
                              body: "yo", direction: .incoming, storeTs: 424242)
    await controller.receive(withSts)
    await controller.applyReaction(thread: "c1", targetSts: 424242, emoji: "❤️", remove: false, senderName: "Peer")
    let list = await controller.messages
    #expect(list.last?.reactions == ["❤️"])
    await controller.applyReaction(thread: "c1", targetSts: 424242, emoji: "❤️", remove: true, senderName: "Peer")
    let after = await controller.messages
    #expect(after.last?.reactions.isEmpty == true)
    await controller.applyReceipt(kind: "read", timestamps: [424242], senderName: "Peer")
    // Incoming messages don't collect receipts; must not crash.
    #expect(await controller.messages.count == 2)
}

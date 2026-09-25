import Foundation
import Testing
@testable import CuztomSignalCore

@Test func inMemoryReplayPreservesLocalMetadata() async {
    let store = MessageStore()
    let conversation = Conversation(
        id: "contact:11111111-1111-1111-1111-111111111111",
        title: "Alice",
        peer: SignalAddress(uuidString: "11111111-1111-1111-1111-111111111111")
    )
    await store.upsertConversation(conversation)
    let author = SignalAddress(uuidString: "11111111-1111-1111-1111-111111111111")
    let file = URL(fileURLWithPath: "/tmp/cuztom-regression-attachment.jpg")
    let first = ChatMessage(
        id: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
        conversationId: conversation.id,
        author: author,
        body: "same",
        direction: .incoming,
        sentAt: Date(timeIntervalSince1970: 10),
        attachments: [AttachmentMeta(filename: "photo.jpg", mimeType: "image/jpeg", byteCount: 3, localURL: file)],
        storeTs: 1000,
        reactions: ["❤️"],
        readBy: ["reader"],
        deliveredTo: ["device"]
    )
    let replay = ChatMessage(
        id: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!,
        conversationId: conversation.id,
        author: author,
        body: "same",
        direction: .incoming,
        sentAt: first.sentAt,
        storeTs: first.storeTs
    )

    #expect(await store.saveMessage(first))
    #expect(!(await store.saveMessage(replay)))
    let stored = await store.message(conversationId: conversation.id, storeTs: 1000)
    #expect(stored?.reactions == ["❤️"])
    #expect(stored?.readBy == ["reader"])
    #expect(stored?.deliveredTo == ["device"])
    #expect(stored?.attachments.first?.localURL == file)

    var edited = replay
    edited.id = UUID()
    edited.body = "edited"
    #expect(!(await store.saveMessage(edited)))
    #expect(await store.message(conversationId: conversation.id, storeTs: 1000)?.body == "edited")

    let zeroA = ChatMessage(
        conversationId: conversation.id,
        author: author,
        body: "zero-a",
        direction: .incoming,
        storeTs: 0
    )
    let zeroB = ChatMessage(
        conversationId: conversation.id,
        author: author,
        body: "zero-b",
        direction: .incoming,
        storeTs: 0
    )
    #expect(await store.saveMessage(zeroA))
    #expect(await store.saveMessage(zeroB))
    #expect(await store.messageCount(in: conversation.id) == 3)
}

@Test func sqlitePersistsReplyReference() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("cuztom-reply-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try SQLiteMessageStore(path: directory)
    let reply = ChatMessage(
        conversationId: "c1",
        author: SignalAddress(uuidString: "11111111-1111-1111-1111-111111111111"),
        body: "reply",
        direction: .incoming,
        replyTo: MessageReference(
            storeTs: 10,
            authorID: "22222222-2222-2222-2222-222222222222",
            body: "original"
        ),
        storeTs: 20
    )
    #expect(await store.saveMessage(reply))
    let loaded = await store.message(conversationId: "c1", storeTs: 20)
    #expect(loaded?.replyTo?.storeTs == 10)
    #expect(loaded?.replyTo?.authorID == "22222222-2222-2222-2222-222222222222")
    #expect(loaded?.replyTo?.body == "original")
}

@Test func sqliteKeepsQuoteOnlyMessageAcrossReopen() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("cuztom-quote-only-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let first = try SQLiteMessageStore(path: directory)
    let message = ChatMessage(
        conversationId: "c1",
        author: SignalAddress(uuidString: "11111111-1111-1111-1111-111111111111"),
        body: "",
        direction: .incoming,
        replyTo: MessageReference(
            storeTs: 10,
            authorID: "22222222-2222-2222-2222-222222222222",
            body: "quoted"
        ),
        storeTs: 20
    )
    #expect(await first.saveMessage(message, countsAsUnread: false))

    // Migration/startup cleanup must retain a legitimate quote-only row.
    let second = try SQLiteMessageStore(path: directory)
    let loaded = await second.message(conversationId: "c1", storeTs: 20)
    #expect(loaded?.replyTo?.storeTs == 10)
    #expect(loaded?.body.isEmpty == true)
}

@Test @MainActor func controllerAcceptsQuoteOnlyIncomingMessage() async {
    let conversation = Conversation(id: "c1", title: "Peer", peer: SignalAddress(phone: "+1"))
    let controller = ChatController(service: MockSignalService(seedConversations: [conversation]))
    await controller.link()
    let message = ChatMessage(
        conversationId: "c1",
        author: SignalAddress(phone: "+1"),
        body: "",
        direction: .incoming,
        replyTo: MessageReference(storeTs: 10, body: "quoted"),
        storeTs: 20
    )
    await controller.receive(message)
    await controller.select("c1")
    #expect(controller.messages.count == 1)
    #expect(controller.messages.first?.replyTo?.storeTs == 10)
}

@Test func sqlitePagingReturnsNewestPageAndHistoricalImportsDoNotMarkUnread() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("cuztom-paging-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try SQLiteMessageStore(path: directory)
    let conversation = Conversation(
        id: "contact:22222222-2222-2222-2222-222222222222",
        title: "History",
        peer: SignalAddress(uuidString: "22222222-2222-2222-2222-222222222222")
    )
    await store.upsertConversation(conversation)
    let author = SignalAddress(uuidString: conversation.peer.uuidString!)
    for index in 1...205 {
        let message = ChatMessage(
            conversationId: conversation.id,
            author: author,
            body: "m\(index)",
            direction: .incoming,
            sentAt: Date(timeIntervalSince1970: TimeInterval(index)),
            storeTs: Int64(index)
        )
        _ = await store.saveMessage(message, countsAsUnread: false)
    }
    let page = await store.messages(in: conversation.id, limit: 200)
    #expect(page.count == 200)
    #expect(page.first?.body == "m6")
    #expect(page.last?.body == "m205")
    #expect(await store.allConversations().first?.unreadCount == 0)

    let live = ChatMessage(
        conversationId: conversation.id,
        author: author,
        body: "live",
        direction: .incoming,
        sentAt: Date(timeIntervalSince1970: 206),
        storeTs: 206
    )
    #expect(await store.saveMessage(live, countsAsUnread: true))
    #expect(await store.allConversations().first?.unreadCount == 1)
    var edited = live
    edited.id = UUID()
    edited.body = "edited"
    #expect(!(await store.saveMessage(edited)))
    #expect(await store.message(conversationId: conversation.id, storeTs: 206)?.body == "edited")
    var rosterRefresh = conversation
    rosterRefresh.unreadCount = 0
    await store.upsertConversation(rosterRefresh)
    #expect(await store.allConversations().first?.unreadCount == 1)
    try await store.clearAllDataChecked()
    #expect(await store.totalMessageCount() == 0)
    #expect(await store.allConversations().isEmpty)
}

@Test @MainActor func controllerPropagatesLiveStateChanges() async {
    let conversation = Conversation(id: "c1", title: "Peer", peer: SignalAddress(phone: "+1"))
    let controller = ChatController(service: MockSignalService(seedConversations: [conversation]))
    var changes = 0
    controller.onStateChange = { changes += 1 }
    await controller.link()
    let before = changes
    await controller.receive(ChatMessage(
        conversationId: "c1",
        author: SignalAddress(phone: "+1"),
        body: "live",
        direction: .incoming,
        storeTs: 42
    ))
    #expect(changes > before)
    #expect(controller.messages.isEmpty) // not selected yet
    await controller.select("c1")
    #expect(controller.messages.count == 1)
}

@Test @MainActor func controllerAppliesRemoteEditAndDeleteByStableTimestamp() async {
    let conversation = Conversation(id: "c1", title: "Peer", peer: SignalAddress(phone: "+1"))
    let authorID = "11111111-1111-1111-1111-111111111111"
    let store = MessageStore()
    let seed = ChatMessage(
        conversationId: "c1",
        author: SignalAddress(uuidString: authorID),
        body: "before",
        direction: .incoming,
        storeTs: 777
    )
    let service = MockSignalService(seedConversations: [conversation], seedMessages: ["c1": [seed]])
    let controller = ChatController(service: service, store: store)
    await controller.link()
    await controller.select("c1")
    await controller.applyEdit(
        thread: "c1",
        targetSts: 777,
        body: "after",
        senderID: "22222222-2222-2222-2222-222222222222",
        senderName: "Impostor"
    )
    #expect(controller.messages.first?.body == "before")
    await controller.applyEdit(
        thread: "c1",
        targetSts: 777,
        body: "after",
        senderID: authorID,
        senderName: "Peer"
    )
    #expect(controller.messages.first?.body == "after")
    await controller.applyDelete(
        thread: "c1",
        targetSts: 777,
        senderID: authorID,
        senderName: "Peer"
    )
    #expect(controller.messages.isEmpty)
}

@Test func liveControlEventsDecode() throws {
    let edit = """
    {"type":"edit","thread":"contact:x","target_sts":42,"body":"new","sender":"x","sender_name":"Peer"}
    """
    let decodedEdit = try JSONDecoder().decode(LiveEvent.self, from: Data(edit.utf8))
    #expect(decodedEdit.type == "edit")
    #expect(decodedEdit.targetSts == 42)
    #expect(decodedEdit.body == "new")

    let delete = """
    {"type":"delete","thread":"contact:x","target_sts":42,"sender":"x","sender_name":"Peer"}
    """
    let decodedDelete = try JSONDecoder().decode(LiveEvent.self, from: Data(delete.utf8))
    #expect(decodedDelete.type == "delete")
    #expect(decodedDelete.targetSts == 42)
}

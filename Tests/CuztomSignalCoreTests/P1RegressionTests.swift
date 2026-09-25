import Foundation
import Testing
@testable import CuztomSignalCore

@Test @MainActor func scopedReceiptsDoNotCrossCollidingConversations() async {
    let first = Conversation(
        id: "contact:11111111-1111-1111-1111-111111111111",
        title: "First",
        peer: SignalAddress(uuidString: "11111111-1111-1111-1111-111111111111")
    )
    let second = Conversation(
        id: "contact:22222222-2222-2222-2222-222222222222",
        title: "Second",
        peer: SignalAddress(uuidString: "22222222-2222-2222-2222-222222222222")
    )
    let firstMessage = ChatMessage(
        conversationId: first.id,
        author: SignalAddress(uuidString: "self"),
        body: "first",
        direction: .outgoing,
        storeTs: 900
    )
    let secondMessage = ChatMessage(
        conversationId: second.id,
        author: SignalAddress(uuidString: "self"),
        body: "second",
        direction: .outgoing,
        storeTs: 900
    )
    let service = MockSignalService(
        seedConversations: [first, second],
        seedMessages: [first.id: [firstMessage], second.id: [secondMessage]]
    )
    let controller = ChatController(service: service)
    await controller.link()

    await controller.applyReceipt(
        kind: "read",
        timestamps: [900],
        thread: first.id,
        senderID: "11111111-1111-1111-1111-111111111111"
    )

    await controller.select(first.id)
    #expect(controller.messages.first?.readBy == ["11111111-1111-1111-1111-111111111111"])
    await controller.select(second.id)
    #expect(controller.messages.first?.readBy.isEmpty == true)
}

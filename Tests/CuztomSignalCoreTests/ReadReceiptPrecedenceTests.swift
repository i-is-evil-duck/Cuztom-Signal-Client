import Foundation
import Testing

@testable import CuztomSignalCore

/// A member who has seen a message has, by definition, received it.
///
/// Recording both is not a cosmetic duplication — it reports a state that cannot
/// exist, and it was visible: a member appeared under "Seen by" *and* again under
/// "Delivered to" in the same message info popover.
@Suite("Read receipt precedence")
struct ReadReceiptPrecedenceTests {
    private func outgoing() -> ChatMessage {
        ChatMessage(
            conversationId: "group:test",
            author: SignalAddress(uuidString: "00000000-0000-4000-8000-000000000001", displayName: "me"),
            body: "hello",
            direction: .outgoing
        )
    }

    @Test func readingRemovesTheEarlierDeliveryReceipt() {
        var message = outgoing()
        message.recordDelivered(to: "alice")
        #expect(message.deliveredTo == ["alice"])

        message.recordRead(by: "alice")

        #expect(message.readBy == ["alice"])
        #expect(
            message.deliveredTo.isEmpty,
            "having read it is the stronger statement, so the delivery receipt is redundant"
        )
    }

    /// Receipts can arrive in either order and out of order batches happen, so a
    /// late delivery receipt must not move somebody back out of the reader list.
    @Test func aLaterDeliveryReceiptDoesNotUnreadTheMessage() {
        var message = outgoing()
        message.recordRead(by: "alice")
        message.recordDelivered(to: "alice")

        #expect(message.readBy == ["alice"])
        #expect(message.deliveredTo.isEmpty)
    }

    @Test func otherMembersAreUnaffected() {
        var message = outgoing()
        message.recordDelivered(to: "alice")
        message.recordDelivered(to: "bob")
        message.recordRead(by: "alice")

        #expect(message.readBy == ["alice"])
        #expect(
            message.deliveredTo == ["bob"],
            "only the member who read it moves; everyone else keeps their receipt"
        )
    }

    @Test func recordingIsIdempotent() {
        var message = outgoing()
        message.recordRead(by: "alice")
        message.recordRead(by: "alice")
        message.recordDelivered(to: "bob")
        message.recordDelivered(to: "bob")

        #expect(message.readBy == ["alice"])
        #expect(message.deliveredTo == ["bob"])
    }

    /// Messages already on disk were written before this rule existed, so the
    /// invariant has to hold on the way in rather than needing a migration.
    @Test func rowsWrittenBeforeTheRuleAreCorrectedOnRead() {
        let message = ChatMessage(
            conversationId: "group:test",
            author: SignalAddress(uuidString: "00000000-0000-4000-8000-000000000001", displayName: "me"),
            body: "hello",
            direction: .outgoing,
            readBy: ["alice"],
            deliveredTo: ["alice", "bob"]
        )

        #expect(message.readBy == ["alice"])
        #expect(
            message.deliveredTo == ["bob"],
            "a row that still lists a reader as delivered-only is corrected when it is loaded"
        )
    }
}

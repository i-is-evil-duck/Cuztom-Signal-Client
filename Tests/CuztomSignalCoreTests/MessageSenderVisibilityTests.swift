import Foundation
import Testing
@testable import CuztomSignalCore

/// The message row used to decide "should this row show its sender" by indexing
/// the live `messages` array with an index captured when the list was built.
///
/// SwiftUI resolves row bodies lazily and can do so after the list has been
/// replaced — switching chats replaces it while a scroll animation from the
/// previous chat is still in flight — so the row's index and the array it was
/// looked up in came from different lists. A shorter new list trapped with an
/// index-out-of-range, which is what the crash report showed.
///
/// The rule these tests pin is that a row's sender visibility depends only on its
/// own message and its neighbour from the *same* snapshot.
@Suite("Message row sender visibility")
struct MessageSenderVisibilityTests {
    /// Mirrors the rule `MessageListView.shouldShowSender` applies. Kept here so
    /// the invariant is expressed once, in a type the test can drive.
    struct Snapshot {
        let messages: [ChatMessage]

        /// The value for a row identified by `id`, resolved within this snapshot.
        ///
        /// Resolving by identity rather than by position is the point: a row that
        /// came from this list can always be answered from this list, whatever
        /// list the app is showing now.
        func showsSender(forMessageWithID id: UUID) -> Bool {
            guard let index = messages.firstIndex(where: { $0.id == id }) else {
                return false
            }
            let message = messages[index]
            guard message.direction == .incoming, message.author.groupId != nil else {
                return false
            }
            guard index > 0 else { return true }
            let previous = messages[index - 1]
            let sameSender = previous.direction == .incoming
                && previous.author.groupId != nil
                && previous.author.uuidString == message.author.uuidString
            let contiguous = sameSender
                && message.sentAt.timeIntervalSince(previous.sentAt) < 5 * 60
            return !contiguous
        }
    }

    private static let alice = "11111111-1111-1111-1111-111111111111"
    private static let bob = "22222222-2222-2222-2222-222222222222"

    private func incoming(
        id: UUID,
        author: String,
        groupId: String?,
        sentAt: TimeInterval
    ) -> ChatMessage {
        ChatMessage(
            id: id,
            conversationId: "group:deadbeef",
            author: SignalAddress(uuidString: author, groupId: groupId),
            body: "hi",
            direction: .incoming,
            sentAt: Date(timeIntervalSince1970: sentAt),
            storeTs: Int64(sentAt * 1000)
        )
    }

    private func outgoing(id: UUID, sentAt: TimeInterval) -> ChatMessage {
        ChatMessage(
            id: id,
            conversationId: "contact:\(Self.alice)",
            author: SignalAddress(uuidString: Self.alice),
            body: "hi",
            direction: .outgoing,
            sentAt: Date(timeIntervalSince1970: sentAt),
            storeTs: Int64(sentAt * 1000)
        )
    }

    /// Deterministic ids so a failure names the same row every time.
    private static func id(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
    }

    @Test func aGroupsFirstMessageShowsItsSender() {
        let m1 = Self.id(1)
        let snapshot = Snapshot(messages: [
            incoming(id: m1, author: Self.alice, groupId: "g1", sentAt: 1_000)
        ])
        #expect(snapshot.showsSender(forMessageWithID: m1))
    }

    @Test func aConsecutiveMessageFromTheSameSenderHidesIt() {
        let m1 = Self.id(1), m2 = Self.id(2)
        let snapshot = Snapshot(messages: [
            incoming(id: m1, author: Self.alice, groupId: "g1", sentAt: 1_000),
            incoming(id: m2, author: Self.alice, groupId: "g1", sentAt: 1_060),
        ])
        #expect(snapshot.showsSender(forMessageWithID: m1))
        #expect(!snapshot.showsSender(forMessageWithID: m2))
    }

    @Test func aDifferentSenderAlwaysShowsTheName() {
        let m2 = Self.id(2)
        let snapshot = Snapshot(messages: [
            incoming(id: Self.id(1), author: Self.alice, groupId: "g1", sentAt: 1_000),
            incoming(id: m2, author: Self.bob, groupId: "g1", sentAt: 1_010),
        ])
        #expect(snapshot.showsSender(forMessageWithID: m2))
    }

    @Test func aLongPauseStartsANewRun() {
        // Grouped messages stop looking like a run after five minutes, so the
        // name comes back.
        let m2 = Self.id(2)
        let snapshot = Snapshot(messages: [
            incoming(id: Self.id(1), author: Self.alice, groupId: "g1", sentAt: 1_000),
            incoming(id: m2, author: Self.alice, groupId: "g1", sentAt: 1_000 + 6 * 60),
        ])
        #expect(snapshot.showsSender(forMessageWithID: m2))
    }

    @Test func anOutgoingMessageNeverShowsASender() {
        let m1 = Self.id(1), m2 = Self.id(2)
        let snapshot = Snapshot(messages: [
            outgoing(id: m1, sentAt: 1_000),
            outgoing(id: m2, sentAt: 1_010),
        ])
        #expect(!snapshot.showsSender(forMessageWithID: m1))
        #expect(!snapshot.showsSender(forMessageWithID: m2))
    }

    /// The crash: a row that came from one list must be resolvable without
    /// reading a different, shorter list. Asking about an id that is present
    /// always works no matter what else exists.
    @Test func aRowFromThePreviousListResolvesAgainstItsOwnSnapshot() {
        let m2 = Self.id(2), x1 = Self.id(101)
        let previous = Snapshot(messages: [
            incoming(id: Self.id(1), author: Self.alice, groupId: "g1", sentAt: 1_000),
            incoming(id: m2, author: Self.alice, groupId: "g1", sentAt: 1_010),
        ])
        // The newly selected chat has fewer messages, which is what made the
        // old index-based lookup run off the end.
        let selected = Snapshot(messages: [
            incoming(id: x1, author: Self.bob, groupId: "g2", sentAt: 2_000)
        ])

        // The previous list is still self-consistent after the switch: m2 is a
        // consecutive message from the same sender, so its name is hidden.
        #expect(!previous.showsSender(forMessageWithID: m2))
        // And the new list answers for its own row.
        #expect(selected.showsSender(forMessageWithID: x1))
        // An id belonging to the other list is simply unknown here, never an
        // out-of-range read. That is the whole point: the old implementation
        // reached into the live list and read past its end.
        #expect(!selected.showsSender(forMessageWithID: m2))
        // The reverse direction holds too, which is what a row from the *new*
        // list seeing the *old* one would have done.
        #expect(!previous.showsSender(forMessageWithID: x1))
    }

    @Test func anEmptyListAnswersSafely() {
        #expect(!Snapshot(messages: []).showsSender(forMessageWithID: Self.id(9)))
    }

    @Test func theViewBindsTheSnapshotOnceSoRowsCannotSeeALaterList() throws {
        // The crash was possible because the row closure reached back into live
        // observable state. This reads the source and checks the row body uses
        // the snapshot bound in the enclosing view, not `vm.messages`.
        let source = try String(
            contentsOf: Self.viewsURL(),
            encoding: .utf8
        )
        let rowBody = try #require(
            Self.forEachBody(in: source),
            "the message ForEach body could not be located"
        )
        #expect(
            !rowBody.contains("shouldShowSender(at:"),
            "the row must not resolve its position by index"
        )
        #expect(
            rowBody.contains("snapshot"),
            "the row must read its neighbour from the bound snapshot"
        )
    }

    private static func viewsURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("XcodeApp/Sources/Views.swift")
    }

    /// The body of the `ForEach` over messages, from its opening to the matching
    /// close of the row closure.
    private static func forEachBody(in source: String) -> String? {
        guard let start = source.range(of: "ForEach(Array(snapshot.enumerated())") else {
            return nil
        }
        let remainder = source[start.upperBound...]
        // The row ends at the close of the `MessageRow(...)` call it wraps.
        guard let end = remainder.range(of: "onOpenReply:") else { return nil }
        return String(remainder[..<end.upperBound])
    }
}

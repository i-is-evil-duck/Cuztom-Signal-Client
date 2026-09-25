import Foundation
import Testing
@testable import CuztomSignalCore

/// Opening a chat must show the newest messages, not the oldest, and older
/// history must arrive only when asked for.
///
/// The paging itself is already correct in the store — newest N, returned in
/// ascending order so the newest is last. What was wrong was the *presentation*:
/// the list rendered at the top and then jumped to the bottom, which read as
/// "loads from the top then scrolls", and older pages were only reachable through
/// a button. These tests pin the store ordering that the scroll behaviour relies
/// on, because a regression there would silently reopen both problems.
@Suite("Message history paging")
struct MessageHistoryPagingTests {
    private func makeStore() throws -> SQLiteMessageStore {
        try SQLiteMessageStore(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("paging-\(UUID().uuidString)"))
    }

    private func message(
        _ index: Int,
        at seconds: TimeInterval
    ) -> ChatMessage {
        ChatMessage(
            conversationId: "group:deadbeef",
            author: SignalAddress(uuidString: "11111111-1111-1111-1111-111111111111", groupId: "deadbeef"),
            body: "message \(index)",
            direction: .incoming,
            status: .delivered,
            sentAt: Date(timeIntervalSince1970: seconds),
            storeTs: Int64(seconds * 1000)
        )
    }

    @Test func aNewThreadOpensOnItsNewestMessages() async throws {
        let store = try makeStore()
        // Written oldest first, which is the order history arrives in.
        for index in 0..<250 {
            await store.saveMessage(
                message(index, at: 1_700_000_000 + Double(index) * 60),
                countsAsUnread: false
            )
        }

        let page = await store.messages(in: "group:deadbeef", limit: 200)

        #expect(page.count == 200, "the newest page is the requested size")
        // The newest message is present, and it is last so it renders at the
        // bottom. Opening a chat and seeing the oldest messages is the bug this
        // ordering prevents.
        #expect(page.last?.body == "message 249")
        #expect(!page.contains { $0.body == "message 0" })
        // Ascending, so the list reads top to bottom.
        let timestamps = page.map(\.sentAt)
        #expect(timestamps == timestamps.sorted(), "rows must be oldest first")
    }

    @Test func aShortThreadIsReturnedWhole() async throws {
        let store = try makeStore()
        for index in 0..<5 {
            await store.saveMessage(message(index, at: 1_700_000_000 + Double(index)), countsAsUnread: false)
        }
        let page = await store.messages(in: "group:deadbeef", limit: 200)
        #expect(page.count == 5)
        #expect(page.last?.body == "message 4")
    }

    @Test func growingTheLimitReachesFurtherBackWithoutLosingTheNewest() async throws {
        // This is what "load older" does: the limit grows, so the page reaches
        // further into the past while still ending at the newest message.
        let store = try makeStore()
        for index in 0..<250 {
            await store.saveMessage(
                message(index, at: 1_700_000_000 + Double(index) * 60),
                countsAsUnread: false
            )
        }

        let first = await store.messages(in: "group:deadbeef", limit: 200)
        let grown = await store.messages(in: "group:deadbeef", limit: 250)

        #expect(grown.count == 250)
        #expect(grown.first?.body == "message 0", "the oldest is now reachable")
        // The newest is still last, so the reader's position at the bottom is
        // unchanged after a page is prepended above them.
        #expect(grown.last?.body == "message 249")
        // Nothing was dropped or reordered by growing the window.
        #expect(grown.suffix(200).map(\.id) == first.map(\.id))
    }

    @Test func aZeroLimitYieldsNothingRatherThanEverything() async throws {
        // A limit of zero must not fall back to "no limit": that would load the
        // entire history of a long thread into memory.
        let store = try makeStore()
        for index in 0..<10 {
            await store.saveMessage(message(index, at: 1_700_000_000 + Double(index)), countsAsUnread: false)
        }
        let page = await store.messages(in: "group:deadbeef", limit: 0)
        #expect(page.isEmpty)
    }

    @Test func threadsDoNotLeakIntoEachOther() async throws {
        // The top sentinel fires per chat, so a page loaded for one thread must
        // not appear in another.
        let store = try makeStore()
        for index in 0..<5 {
            await store.saveMessage(message(index, at: 1_700_000_000 + Double(index)), countsAsUnread: false)
            var other = message(index, at: 1_700_000_000 + Double(index))
            other.conversationId = "contact:22222222-2222-2222-2222-222222222222"
            await store.saveMessage(other, countsAsUnread: false)
        }
        let group = await store.messages(in: "group:deadbeef", limit: 200)
        let contact = await store.messages(in: "contact:22222222-2222-2222-2222-222222222222", limit: 200)
        #expect(group.count == 5)
        #expect(contact.count == 5)
        #expect(Set(group.map(\.id)).isDisjoint(with: Set(contact.map(\.id))))
    }
}

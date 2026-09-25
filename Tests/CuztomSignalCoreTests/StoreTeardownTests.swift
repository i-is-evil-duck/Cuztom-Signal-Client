import Foundation
import Testing
@testable import CuztomSignalCore

/// A read that races a logout must not fault.
///
/// `destroy()` closes the GRDB queue, which releases the underlying sqlite
/// handle. A diagnostics read scheduled by the view model was still in flight
/// when logout ran, and it dereferenced the freed connection: the crash was a
/// segfault inside `sqlite3_get_autocommit` with no Swift frame to explain it,
/// because the fault is in C code reached through a stored property.
///
/// These tests drive reads *after* the close, which is the deterministic version
/// of that race, and assert they are skipped rather than fatal.
@Suite("Store teardown safety")
struct StoreTeardownTests {
    private func makeStore() throws -> SQLiteMessageStore {
        try SQLiteMessageStore(
            path: FileManager.default.temporaryDirectory
                .appendingPathComponent("teardown-\(UUID().uuidString)")
        )
    }

    private func conversation(_ id: String) -> Conversation {
        Conversation(id: id, title: "T", peer: SignalAddress(groupId: id))
    }

    @Test func readsAfterDestroyAreSkippedRatherThanFaulting() async throws {
        let store = try makeStore()
        // Give it something to count, so a skipped read is distinguishable from
        // an empty store.
        let conversation = self.conversation("group:aa")
        await store.upsertConversation(conversation)
        let message = ChatMessage(
            conversationId: conversation.id,
            author: SignalAddress(uuidString: "11111111-1111-1111-1111-111111111111"),
            body: "hello",
            direction: .incoming,
            status: .delivered,
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            storeTs: 1_700_000_000_000
        )
        await store.saveMessage(message, countsAsUnread: false)
        #expect(await store.totalMessageCount() == 1)

        try await store.destroy()

        // The exact call the crash report showed, after the handle is gone.
        #expect(await store.totalMessageCount() == 0)
        #expect(await store.messages(in: conversation.id).isEmpty)
        #expect(await store.allConversations().isEmpty)
    }

    @Test func writesAfterDestroyAreDiscardedRatherThanFaulting() async throws {
        let store = try makeStore()
        try await store.destroy()

        // A write that lands during teardown has nowhere useful to go: the rows
        // it would create are about to be deleted. Skipping is correct, and
        // faulting is not.
        await store.upsertConversation(conversation("group:bb"))
        await store.saveMessage(
            ChatMessage(
                conversationId: "group:bb",
                author: SignalAddress(uuidString: "22222222-2222-2222-2222-222222222222"),
                body: "late",
                direction: .outgoing,
                status: .sent
            ),
            countsAsUnread: false
        )
        #expect(await store.totalMessageCount() == 0)
    }

    @Test func destroyRemovesTheDatabaseFiles() async throws {
        let store = try makeStore()
        let path = await store.databaseFileURL
        #expect(FileManager.default.fileExists(atPath: path.path))
        try await store.destroy()
        #expect(!FileManager.default.fileExists(atPath: path.path))
    }

    @Test func destroyIsSafeToReachMoreThanOnce() async throws {
        // Logout can be attempted twice: once from the menu and once from a
        // failed-state retry. The second attempt must not fault on an already
        // closed connection either.
        let store = try makeStore()
        try await store.destroy()
        await #expect(throws: (any Error).self) {
            try await store.destroy()
        }
        // Still usable as a no-op afterwards.
        #expect(await store.totalMessageCount() == 0)
    }

    @Test func aStoreThatWasNeverDestroyedStillReportsItsRows() async throws {
        // The guard must not be set by anything but `destroy`, or ordinary
        // reads would silently return nothing.
        let store = try makeStore()
        await store.upsertConversation(conversation("group:cc"))
        #expect(await store.allConversations().count == 1)
        #expect(await store.totalMessageCount() == 0)
    }
}

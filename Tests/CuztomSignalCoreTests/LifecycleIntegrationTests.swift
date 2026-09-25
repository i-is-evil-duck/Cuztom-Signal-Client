import Foundation
import Testing
@testable import CuztomSignalCore

private final class BlockingSignalService: SignalService, @unchecked Sendable {
    let connectionState: AsyncStream<ConnectionState>
    private let connectionContinuation: AsyncStream<ConnectionState>.Continuation
    private let waitStarted: AsyncStream<Void>
    private let waitStartedContinuation: AsyncStream<Void>.Continuation
    private let releaseWait: AsyncStream<Void>
    private let releaseWaitContinuation: AsyncStream<Void>.Continuation

    init() {
        var connectionContinuation: AsyncStream<ConnectionState>.Continuation!
        self.connectionState = AsyncStream { connectionContinuation = $0 }
        self.connectionContinuation = connectionContinuation

        var waitStartedContinuation: AsyncStream<Void>.Continuation!
        self.waitStarted = AsyncStream { waitStartedContinuation = $0 }
        self.waitStartedContinuation = waitStartedContinuation

        var releaseWaitContinuation: AsyncStream<Void>.Continuation!
        self.releaseWait = AsyncStream { releaseWaitContinuation = $0 }
        self.releaseWaitContinuation = releaseWaitContinuation
    }

    func beginLinking(deviceName: String) async throws -> LinkQR {
        LinkQR(payload: "blocking://\(deviceName)")
    }

    func waitForLink() async throws {
        waitStartedContinuation.yield(())
        for await _ in releaseWait { break }
    }

    func waitUntilWaitStarted() async {
        for await _ in waitStarted { break }
    }

    func unblockWait() {
        releaseWaitContinuation.yield(())
    }

    func fetchConversations() async throws -> [Conversation] { [] }
    func fetchMessages(conversationId: String, limit: Int) async throws -> [ChatMessage] { [] }

    func sendText(_ body: String, to conversationId: String) async throws -> ChatMessage {
        ChatMessage(
            conversationId: conversationId,
            author: SignalAddress(uuidString: "self"),
            body: body,
            direction: .outgoing
        )
    }

    func incomingMessages() -> AsyncStream<ChatMessage> {
        AsyncStream { $0.finish() }
    }

    deinit {
        connectionContinuation.finish()
        waitStartedContinuation.finish()
        releaseWaitContinuation.finish()
    }
}

private final class ScriptedIncomingService: SignalService, @unchecked Sendable {
    let connectionState: AsyncStream<ConnectionState>
    private let connectionContinuation: AsyncStream<ConnectionState>.Continuation
    private let incoming: AsyncStream<ChatMessage>
    private let incomingContinuation: AsyncStream<ChatMessage>.Continuation

    init() {
        var connectionContinuation: AsyncStream<ConnectionState>.Continuation!
        self.connectionState = AsyncStream { connectionContinuation = $0 }
        self.connectionContinuation = connectionContinuation
        var incomingContinuation: AsyncStream<ChatMessage>.Continuation!
        self.incoming = AsyncStream { incomingContinuation = $0 }
        self.incomingContinuation = incomingContinuation
    }

    func beginLinking(deviceName: String) async throws -> LinkQR {
        LinkQR(payload: "scripted://\(deviceName)")
    }
    func waitForLink() async throws {}
    func fetchConversations() async throws -> [Conversation] { [] }
    func fetchMessages(conversationId: String, limit: Int) async throws -> [ChatMessage] { [] }
    func sendText(_ body: String, to conversationId: String) async throws -> ChatMessage {
        ChatMessage(conversationId: conversationId, author: SignalAddress(uuidString: "self"), body: body, direction: .outgoing)
    }
    func incomingMessages() -> AsyncStream<ChatMessage> { incoming }
    func inject(_ message: ChatMessage) { incomingContinuation.yield(message) }
    func finish() {
        connectionContinuation.finish()
        incomingContinuation.finish()
    }
}

@Test func shutdownStopsWatcherBeforeAccountSwitch() async throws {
    let service = ScriptedIncomingService()
    let controller = await ChatController(service: service)
    await controller.link()
    await controller.shutdown()

    service.inject(ChatMessage(
        conversationId: "contact:old",
        author: SignalAddress(uuidString: "old"),
        body: "stale",
        direction: .incoming
    ))
    try await Task.sleep(nanoseconds: 20_000_000)
    #expect(await controller.messages.isEmpty)
    service.finish()
}

@Test func staleFinishCannotPublishAfterLogout() async throws {
    let service = BlockingSignalService()
    let controller = await ChatController(service: service)

    let finishTask = Task { await controller.finish() }
    await service.waitUntilWaitStarted()

    // Account teardown completes while the old waitForLink continuation is
    // still suspended. Releasing it afterwards must not restore `.connected`.
    try await controller.logoutAndWipe()
    service.unblockWait()

    #expect(!(await finishTask.value))
    #expect(await controller.connection == .unlinked)
    #expect(await controller.isLinked == false)
}

@Test @MainActor func lateNativeCallbackCannotPublishAfterShutdown() async throws {
    // No dylib is loaded here on purpose: the callbacks are plain closures, so
    // the fencing can be exercised without a live native core.
    let dbPath = NSTemporaryDirectory() + "/cuztom-callback-\(UUID().uuidString)"
    let live = RustCoreService(libraryPath: "/nonexistent/lib.dylib", dbPath: dbPath)
    let controller = ChatController(service: live, store: MessageStore())
    controller.installLiveCallbacks(on: live)

    // Positive control: while the controller is current, the callback applies.
    live.onSyncEvent?("contacts synced")
    try await Task.sleep(nanoseconds: 50_000_000)
    #expect(await controller.lastSyncNote == "contacts synced")

    await controller.shutdown()

    // Account B has taken over; a native event already in flight for account A
    // must not reach this controller.
    live.onSyncEvent?("stale account A event")
    live.onEdit?("contact:old", 42, "stale body", "peer", "Peer")
    live.onDelete?("contact:old", 43, "peer", "Peer")
    live.onReceipt?("peer", "delivered", [42])
    live.onTypingWithID?("contact:old", "peer", "Peer", true)
    try await Task.sleep(nanoseconds: 50_000_000)

    #expect(await controller.lastSyncNote == "contacts synced")
    #expect(await controller.messages.isEmpty)
    try? FileManager.default.removeItem(atPath: dbPath)
}

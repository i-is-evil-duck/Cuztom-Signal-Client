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

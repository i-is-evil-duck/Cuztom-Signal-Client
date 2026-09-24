import Foundation

/// Deterministic fake backend for M0 UI + unit tests.
/// Mirrors the future Rust-core behavior (link -> sync -> live stream).
public actor MockSignalService: SignalService {
    private let stateContinuation: AsyncStream<ConnectionState>.Continuation
    public nonisolated let connectionState: AsyncStream<ConnectionState>

    private let incomingContinuation: AsyncStream<ChatMessage>.Continuation
    private let incoming: AsyncStream<ChatMessage>

    private var linked = false
    private var seedConversations: [Conversation]
    private var seedMessages: [String: [ChatMessage]]

    public init(seedConversations: [Conversation] = [], seedMessages: [String: [ChatMessage]] = [:]) {
        self.seedConversations = seedConversations
        self.seedMessages = seedMessages
        var sc: AsyncStream<ConnectionState>.Continuation!
        self.connectionState = AsyncStream { sc = $0 }
        self.stateContinuation = sc
        var ic: AsyncStream<ChatMessage>.Continuation!
        self.incoming = AsyncStream { ic = $0 }
        self.incomingContinuation = ic
    }

    public func beginLinking(deviceName: String) async throws -> LinkQR {
        stateContinuation.yield(.linking)
        return LinkQR(payload: "cuztom-signal://link?device=\(deviceName)&mock=1")
    }

    public func waitForLink() async throws {
        linked = true
        stateContinuation.yield(.connected)
    }

    public func fetchConversations() async throws -> [Conversation] {
        guard linked else { throw SignalError.notLinked }
        return seedConversations
    }

    public func fetchMessages(conversationId: String, limit: Int) async throws -> [ChatMessage] {
        guard linked else { throw SignalError.notLinked }
        return Array((seedMessages[conversationId] ?? []).suffix(limit))
    }

    public func sendText(_ body: String, to conversationId: String) async throws -> ChatMessage {
        guard linked else { throw SignalError.notLinked }
        let msg = ChatMessage(
            conversationId: conversationId,
            author: SignalAddress(uuidString: "self"),
            body: body,
            direction: .outgoing,
            status: .sent
        )
        seedMessages[conversationId, default: []].append(msg)
        return msg
    }

    public nonisolated func incomingMessages() -> AsyncStream<ChatMessage> {
        incoming
    }

    /// Test helper: push a fake inbound message through the stream.
    public func injectIncoming(_ message: ChatMessage) {
        incomingContinuation.yield(message)
    }
}

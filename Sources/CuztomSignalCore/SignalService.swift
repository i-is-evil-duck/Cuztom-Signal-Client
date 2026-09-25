import Foundation

public enum SignalError: Error, Sendable {
    case notLinked
    case alreadyLinked
    case sessionInvalidated
    case network(String)
    case crypto(String)
    case storage(String)
    case unsupported(String)
}

public enum ConnectionState: String, Sendable {
    case unlinked, linking, syncing, connected, offline
}

/// Opaque provisioning payload rendered as QR for the phone to scan.
/// Real bytes come from the Rust core (presage link-device) in M1.
public struct LinkQR: Sendable {
    public var payload: String
    public var expiresAt: Date

    public init(payload: String, expiresAt: Date = Date().addingTimeInterval(120)) {
        self.payload = payload
        self.expiresAt = expiresAt
    }
}

public protocol SignalService: Sendable {
    var connectionState: AsyncStream<ConnectionState> { get }

    /// Start linked-device provisioning. Returns QR payload for UI to render.
    func beginLinking(deviceName: String) async throws -> LinkQR

    /// Poll/wait until the phone confirms linking (or throws on timeout).
    func waitForLink() async throws

    func fetchConversations() async throws -> [Conversation]
    func fetchMessages(conversationId: String, limit: Int) async throws -> [ChatMessage]
    func sendText(_ body: String, to conversationId: String) async throws -> ChatMessage

    /// Live inbound messages. Backed by websocket in Rust core (M1+).
    func incomingMessages() -> AsyncStream<ChatMessage>
}

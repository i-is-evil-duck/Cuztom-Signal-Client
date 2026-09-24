import Foundation

/// Call signaling message types (mirrors RingRTC signaling)
public enum CallSignalType: String, Sendable, Codable {
    case offer
    case answer
    case iceCandidate
    case hangup
    case busy
}

/// Call signaling payload for websocket transport
public struct CallSignalMessage: Sendable, Codable {
    public var callId: String
    public var type: CallSignalType
    public var from: String
    public var to: String
    public var payload: String // SDP or ICE candidate JSON
    public var timestamp: Int64

    public init(callId: String, type: CallSignalType, from: String, to: String, payload: String, timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        self.callId = callId
        self.type = type
        self.from = from
        self.to = to
        self.payload = payload
        self.timestamp = timestamp
    }
}

/// Protocol for call signaling transport (over existing websocket)
public protocol CallSignalTransport: Sendable {
    func sendCallSignal(_ message: CallSignalMessage) async throws
    var incomingCallSignals: AsyncStream<CallSignalMessage> { get }
}

/// M4: Call controller - manages active calls, signaling, and RingRTC integration
@MainActor
public final class CallController: ObservableObject {
    public static let shared = CallController()

    /// Currently active call (if any)
    @Published public private(set) var activeCall: ActiveCall?

    /// Call history
    @Published public private(set) var callHistory: [CallRecord] = []

    /// Incoming call signal handler
    private var signalTask: Task<Void, Never>?
    private var rustCore: RustCoreService?
    private var signalService: (any SignalService)?

    private init() {}

    /// Configure with live signal service (for websocket transport)
    public func configure(with service: any SignalService, transport: CallSignalTransport) {
        self.signalService = service
        // Also store RustCoreService if it's the live backend
        if let rust = service as? RustCoreService {
            self.rustCore = rust
        }
        startListening()
    }

    /// Start an outgoing call
    public func startCall(to conversationId: String, mediaType: CallMediaType, peer: SignalAddress) async throws -> ActiveCall {
        guard activeCall == nil else {
            throw CallError.alreadyInCall
        }

        let callRecord = CallRecord(
            conversationId: conversationId,
            direction: .outgoing,
            mediaType: mediaType,
            state: .dialing,
            startTime: Date(),
            remotePeer: peer
        )

        let activeCall = ActiveCall(callRecord: callRecord)
        self.activeCall = activeCall
        callHistory.append(callRecord)

        // Generate call ID and send offer via RingRTC
        let callId = callRecord.id.uuidString
        try await sendOffer(callId: callId, to: conversationId, mediaType: mediaType)

        return activeCall
    }

    /// Accept an incoming call
    public func answerCall(_ call: ActiveCall) async throws {
        guard let callId = call.callRecord.id.uuidString as String? else { return }
        var updatedCall = call
        updatedCall.callRecord.state = .connecting
        self.activeCall = updatedCall
        try await sendAnswer(callId: callId)
    }

    /// Decline an incoming call
    public func declineCall(_ call: ActiveCall) async throws {
        guard let callId = call.callRecord.id.uuidString as String? else { return }
        var updatedCall = call
        updatedCall.callRecord.state = .ended
        updatedCall.callRecord.endReason = .declined
        updatedCall.callRecord.endTime = Date()
        self.activeCall = nil
        try await sendHangup(callId: callId, reason: .declined)
    }

    /// End the active call
    public func endCall(_ call: ActiveCall) async throws {
        guard let callId = call.callRecord.id.uuidString as String? else { return }
        let wasActive = call.callRecord.state == .active

        var updatedCall = call
        updatedCall.callRecord.state = .ending
        updatedCall.callRecord.endTime = Date()
        updatedCall.callRecord.endReason = wasActive ? .localHangup : .missed

        if wasActive {
            try await sendHangup(callId: callId, reason: .localHangup)
        }

        // Save to history
        callHistory.append(call.callRecord)
        activeCall = nil
    }

    /// Toggle mute
    public func setMuted(_ muted: Bool) {
        activeCall?.muted = muted
        // TODO: RingRTC audio mute
    }

    /// Toggle speaker
    public func setSpeakerOn(_ on: Bool) {
        activeCall?.speakerOn = on
        // TODO: RingRTC audio route
    }

    /// Toggle local video
    public func setLocalVideoEnabled(_ enabled: Bool) {
        activeCall?.localVideoEnabled = enabled
        // TODO: RingRTC video enable/disable
    }

    private func startListening() {
        // TODO: M4 - Implement inbound call signal listening via websocket
        // For now, we only support outbound signaling via RustCoreService FFI
        // The inbound path would need a websocket connection to Signal's call signaling
    }

    private func handleIncomingSignal(_ signal: CallSignalMessage) async {
        // Handle incoming call signals
        switch signal.type {
        case .offer:
            await handleIncomingOffer(signal)
        case .answer:
            await handleAnswer(signal)
        case .iceCandidate:
            await handleIceCandidate(signal)
        case .hangup:
            await handleHangup(signal)
        case .busy:
            await handleBusy(signal)
        }
    }

    private func handleIncomingOffer(_ signal: CallSignalMessage) async {
        guard activeCall == nil else {
            // Send busy response
            try? await sendBusy(callId: signal.callId)
            return
        }

        // Parse offer and create incoming call
        let peer = SignalAddress(uuidString: signal.from)
        let mediaType: CallMediaType = signal.payload.contains("m=video") ? .video : .voice

        let callRecord = CallRecord(
            conversationId: "contact:\(signal.from)",
            direction: .incoming,
            mediaType: mediaType,
            state: .ringing,
            startTime: Date(),
            remotePeer: peer
        )

        let activeCall = ActiveCall(callRecord: callRecord)
        self.activeCall = activeCall

        // Notify UI (will show incoming call screen)
        // TODO: Trigger notification
    }

    private func handleAnswer(_ signal: CallSignalMessage) async {
        // Handle answer to our outgoing offer
        activeCall?.callRecord.state = .connecting
    }

    private func handleIceCandidate(_ signal: CallSignalMessage) async {
        // Forward to RingRTC
    }

    private func handleHangup(_ signal: CallSignalMessage) async {
        activeCall?.callRecord.state = .ended
        activeCall?.callRecord.endReason = .remoteHangup
        activeCall?.callRecord.endTime = Date()
        callHistory.append(activeCall!.callRecord)
        activeCall = nil
    }

    private func handleBusy(_ signal: CallSignalMessage) async {
        activeCall?.callRecord.state = .ended
        activeCall?.callRecord.endReason = .declined
        activeCall?.callRecord.endTime = Date()
        callHistory.append(activeCall!.callRecord)
        activeCall = nil
    }

    private func sendOffer(callId: String, to conversationId: String, mediaType: CallMediaType) async throws {
        guard let rust = rustCore else { throw CallError.signalingFailed("No RustCoreService") }
        // Generate a basic SDP offer for the media type
        let sdp = generateSdpOffer(mediaType: mediaType)
        try await rust.sendCallOffer(callId: callId, to: conversationId, mediaType: mediaType.rawValue, sdp: sdp)
    }

    private func sendAnswer(callId: String) async throws {
        guard let rust = rustCore else { throw CallError.signalingFailed("No RustCoreService") }
        // Generate a basic SDP answer
        let sdp = generateSdpAnswer()
        try await rust.sendCallAnswer(callId: callId, sdp: sdp)
    }

    private func sendHangup(callId: String, reason: CallEndReason) async throws {
        guard let rust = rustCore else { throw CallError.signalingFailed("No RustCoreService") }
        try await rust.sendCallHangup(callId: callId, reason: reason.rawValue)
    }

    private func sendBusy(callId: String) async throws {
        guard let rust = rustCore else { throw CallError.signalingFailed("No RustCoreService") }
        try await rust.sendCallHangup(callId: callId, reason: CallEndReason.declined.rawValue)
    }

    /// Generate a basic SDP offer
    private func generateSdpOffer(mediaType: CallMediaType) -> String {
        let timestamp = Int64(Date().timeIntervalSince1970)
        let mediaLine = mediaType == .video ? "m=video 9 UDP/TLS/RTP/SAVPF 96" : "m=audio 9 UDP/TLS/RTP/SAVPF 111"
        return """
        v=0
        o=- \(timestamp) 2 IN IP4 127.0.0.1
        s=-
        t=0 0
        \(mediaLine)
        a=rtcp-mux
        a=setup:actpass
        a=fingerprint:sha-256 00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00
        a=mid:0
        """

    }

    /// Generate a basic SDP answer
    private func generateSdpAnswer() -> String {
        let timestamp = Int64(Date().timeIntervalSince1970)
        return """
        v=0
        o=- \(timestamp) 2 IN IP4 127.0.0.1
        s=-
        t=0 0
        m=audio 9 UDP/TLS/RTP/SAVPF 111
        a=rtcp-mux
        a=setup:active
        a=fingerprint:sha-256 00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00
        a=mid:0
        """
    }
}

public enum CallError: Error, LocalizedError {
    case alreadyInCall
    case noActiveCall
    case signalingFailed(String)
    case ringrtcError(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyInCall: return "Already in a call"
        case .noActiveCall: return "No active call"
        case .signalingFailed(let s): return "Signaling failed: \(s)"
        case .ringrtcError(let s): return "RingRTC error: \(s)"
        }
    }
}
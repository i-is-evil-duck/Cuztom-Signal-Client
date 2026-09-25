import Foundation
import AVFoundation

/// A decoded call signal lifted out of the Signal receive stream.
///
/// Signal carries call signaling as a `CallMessage` content body whose
/// payload is a RingRTC protobuf blob (`opaque`, base64) — not raw SDP.
public struct CallSignal: Sendable, Decodable, Identifiable {
    public enum Kind: String, Sendable, Codable {
        case offer, answer, ice, hangup, busy
    }

    public var id: String { "\(callId)-\(kind.rawValue)-\(timestamp)" }

    public var kind: Kind
    /// Thread the call belongs to (`contact:<aci>` or `group:<hex>`).
    public var thread: String
    public var sender: String
    public var senderName: String
    public var callId: UInt64
    public var mediaType: String?
    /// RingRTC protobuf payload, base64.
    public var opaque: String?
    /// 0 normal, 1 accepted, 2 declined, 3 busy, 4 need-permission.
    public var hangupType: Int?
    public var deviceId: Int?
    public var timestamp: Int64

    private enum CodingKeys: String, CodingKey {
        case kind, thread, sender, opaque
        case senderName = "sender_name"
        case callId = "call_id"
        case mediaType = "media_type"
        case hangupType = "hangup_type"
        case deviceId = "device_id"
        case ts
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        thread = try c.decode(String.self, forKey: .thread)
        sender = try c.decode(String.self, forKey: .sender)
        senderName = try c.decodeIfPresent(String.self, forKey: .senderName) ?? ""
        callId = try c.decodeIfPresent(UInt64.self, forKey: .callId) ?? 0
        mediaType = try c.decodeIfPresent(String.self, forKey: .mediaType)
        opaque = try c.decodeIfPresent(String.self, forKey: .opaque)
        hangupType = try c.decodeIfPresent(Int.self, forKey: .hangupType)
        deviceId = try c.decodeIfPresent(Int.self, forKey: .deviceId)
        timestamp = try c.decodeIfPresent(Int64.self, forKey: .ts) ?? 0
    }
}

/// A state transition emitted by the native RingRTC media engine.
public struct CallStateEvent: Sendable, Decodable {
    public var thread: String
    public var callId: UInt64
    public var state: String

    private enum CodingKeys: String, CodingKey {
        case thread, state
        case callId = "call_id"
    }
}

/// Legacy SDP-shaped signaling payload retained for source compatibility with
/// the original call transport API. The live backend does not use raw SDP.
public enum CallSignalType: String, Sendable, Codable {
    case offer
    case answer
    case iceCandidate
    case hangup
    case busy
}

public struct CallSignalMessage: Sendable, Codable {
    public var callId: String
    public var type: CallSignalType
    public var from: String
    public var to: String
    public var payload: String
    public var timestamp: Int64

    public init(
        callId: String,
        type: CallSignalType,
        from: String,
        to: String,
        payload: String,
        timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) {
        self.callId = callId
        self.type = type
        self.from = from
        self.to = to
        self.payload = payload
        self.timestamp = timestamp
    }
}

public protocol CallSignalTransport: Sendable {
    func sendCallSignal(_ message: CallSignalMessage) async throws
    var incomingCallSignals: AsyncStream<CallSignalMessage> { get }
}

/// Coordinates the UI-facing call state with the native RingRTC engine.
///
/// The Rust core owns WebRTC, ICE, DTLS/SRTP, microphone capture, and Signal
/// signaling. This class only translates core events into the app's call
/// state and provides the small set of user actions needed by the UI.
@MainActor
public final class CallController: ObservableObject {
    public static let shared = CallController()

    @Published public private(set) var activeCall: ActiveCall?
    @Published public private(set) var callHistory: [CallRecord] = []

    /// Called on the main actor whenever the incoming-call overlay changes.
    public var onIncomingCallChanged: ((ActiveCall?) -> Void)?
    /// Called on the main actor whenever the connected/in-progress overlay changes.
    public var onActiveCallChanged: ((ActiveCall?) -> Void)?

    private var rustCore: RustCoreService?
    private var signalTask: Task<Void, Never>?
    private var nativeIDByRecord: [UUID: UInt64] = [:]
    private var recordIDByNativeID: [UInt64: UUID] = [:]
    private var finishedNativeIDs: Set<UInt64> = []
    /// RingRTC may receive an answer request before its state machine reaches
    /// `Ringing`; keep the request until that native state is observed.
    private var nativeReadyIDs: Set<UInt64> = []
    private var nativeStates: [UInt64: String] = [:]
    private var pendingAcceptIDs: Set<UInt64> = []
    /// A remote hangup can arrive in the same receive batch as the final ICE
    /// answer. RingRTC may still report `connected` immediately afterwards;
    /// keep the call visible briefly and let the native terminal state win if
    /// the hangup was real.
    private var pendingRemoteEndReasons: [UInt64: CallEndReason] = [:]

    private init() {}

    public func configure(with service: any SignalService, transport: any CallSignalTransport) {
        _ = transport // retained in the signature for existing integrations
        signalTask?.cancel()
        signalTask = nil
        rustCore?.onCallSignal = nil
        rustCore?.onCallState = nil
        guard let rust = service as? RustCoreService else {
            rustCore = nil
            return
        }
        rustCore = rust
        rust.onCallSignal = { [weak self] signal in
            Task { @MainActor [weak self] in
                self?.receive(signal)
            }
        }
        rust.onCallState = { [weak self] event in
            Task { @MainActor [weak self] in
                self?.receive(event)
            }
        }
    }

    /// Start an outgoing native call.
    public func startCall(
        to conversationId: String,
        mediaType: CallMediaType,
        peer: SignalAddress
    ) async throws -> ActiveCall {
        guard activeCall == nil else { throw CallError.alreadyInCall }
        try await ensureMicrophonePermission()
        guard let rust = rustCore else { throw CallError.signalingFailed("call core unavailable") }
        guard !peer.isGroup else { throw CallError.signalingFailed("group calls are not supported") }

        let record = CallRecord(
            conversationId: conversationId,
            direction: .outgoing,
            mediaType: mediaType,
            state: .dialing,
            startTime: Date(),
            remotePeer: peer
        )
        let rustMedia = mediaType == .video ? "video" : "audio"
        let nativeID = try await rust.startCall(thread: conversationId, mediaType: rustMedia)
        try? await rust.setCallMuted(false)
        nativeIDByRecord[record.id] = nativeID
        recordIDByNativeID[nativeID] = record.id
        finishedNativeIDs.remove(nativeID)

        let call = ActiveCall(callRecord: record)
        activeCall = call
        onActiveCallChanged?(call)
        return call
    }

    /// Accept an incoming call and ask RingRTC to send its answer.
    public func answerCall(_ call: ActiveCall) async throws {
        try await ensureMicrophonePermission()
        guard let nativeID = nativeIDByRecord[call.callRecord.id] else {
            throw CallError.signalingFailed("incoming call has no native id")
        }

        // `accept_call` is valid only after RingRTC reaches Ringing. The
        // signal envelope can reach Swift before that state transition, so
        // queue the request and let receive(_:) issue it at the safe point.
        guard !pendingAcceptIDs.contains(nativeID) else { return }
        pendingAcceptIDs.insert(nativeID)

        Log.info("call UI: answer requested for native call \(nativeID)")
        // Move the UI out of the incoming overlay immediately. The native
        // accept command remains deferred until RingRTC reports Ringing, but
        // the user should see the connecting/active call screen right away.
        var connecting = call
        connecting.callRecord.state = .connecting
        activeCall = connecting
        onIncomingCallChanged?(nil)
        onActiveCallChanged?(connecting)

        if nativeReadyIDs.contains(nativeID) {
            performAccept(nativeID: nativeID)
        }
    }

    private func performAccept(nativeID: UInt64) {
        pendingAcceptIDs.remove(nativeID)
        guard let rust = rustCore,
              let recordID = recordIDByNativeID[nativeID],
              let call = activeCall,
              call.callRecord.id == recordID else { return }
        Task { @MainActor [weak self] in
            do {
                try await rust.acceptCall(callId: nativeID)
                guard let self, let current = self.activeCall,
                      current.callRecord.id == recordID else { return }
                var updated = current
                updated.callRecord.state = .connecting
                self.activeCall = updated
                self.onIncomingCallChanged?(nil)
                self.onActiveCallChanged?(updated)
            } catch {
                guard let self, let current = self.activeCall,
                      current.callRecord.id == recordID else { return }
                // Leave the call in Ringing so the user can retry.
                var retry = current
                retry.callRecord.state = .ringing
                self.activeCall = retry
                self.onIncomingCallChanged?(retry)
                Log.error("call accept failed: \(error.localizedDescription)")
            }
        }
    }

    /// Decline an incoming call. RingRTC emits the normal local hangup signal.
    public func declineCall(_ call: ActiveCall) async throws {
        try await endCall(call, reason: .declined)
    }

    /// End the active call.
    public func endCall(_ call: ActiveCall) async throws {
        try await endCall(call, reason: .localHangup)
    }

    private func endCall(_ call: ActiveCall, reason: CallEndReason) async throws {
        guard let rust = rustCore else { throw CallError.signalingFailed("call core unavailable") }
        if let nativeID = nativeIDByRecord[call.callRecord.id] {
            try await rust.hangupCall()
            // Keep the ID until the native state callback arrives. If the
            // callback is lost, the fallback below still cleans up the UI.
            if finishedNativeIDs.contains(nativeID) == false {
                var ending = call
                ending.callRecord.state = .ending
                activeCall = ending
                onActiveCallChanged?(ending)
                let recordID = call.callRecord.id
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    guard let self,
                          let current = self.activeCall,
                          current.callRecord.id == recordID else { return }
                    self.finish(current, reason: reason)
                }
            }
        } else {
            finish(call, reason: reason)
        }
    }

    public func setMuted(_ muted: Bool) {
        if let rust = rustCore {
            Task { try? await rust.setCallMuted(muted) }
        }
        guard var call = activeCall else { return }
        call.muted = muted
        activeCall = call
        onActiveCallChanged?(call)
    }

    public func setSpeakerOn(_ on: Bool) {
        guard var call = activeCall else { return }
        call.speakerOn = on
        activeCall = call
        onActiveCallChanged?(call)
    }

    public func setLocalVideoEnabled(_ enabled: Bool) {
        guard var call = activeCall else { return }
        call.localVideoEnabled = enabled
        activeCall = call
        onActiveCallChanged?(call)
    }

    private func ensureMicrophonePermission() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { value in
                    continuation.resume(returning: value)
                }
            }
            guard granted else { throw CallError.microphonePermissionDenied }
        case .denied, .restricted:
            throw CallError.microphonePermissionDenied
        @unknown default:
            throw CallError.microphonePermissionDenied
        }
    }

    /// Clear UI/call identity state when the Signal session is logged out.
    public func reset() {
        if let rust = rustCore {
            Task { try? await rust.setCallMuted(false) }
        }
        activeCall = nil
        nativeIDByRecord.removeAll()
        recordIDByNativeID.removeAll()
        finishedNativeIDs.removeAll()
        nativeReadyIDs.removeAll()
        nativeStates.removeAll()
        pendingAcceptIDs.removeAll()
        pendingRemoteEndReasons.removeAll()
        onIncomingCallChanged?(nil)
        onActiveCallChanged?(nil)
        rustCore?.onCallSignal = nil
        rustCore?.onCallState = nil
        rustCore = nil
    }

    // MARK: - Core events

    private func receive(_ signal: CallSignal) {
        guard rustCore != nil else { return }
        switch signal.kind {
        case .offer:
            Log.info("call UI: received offer while active=\(activeCall != nil)")
            guard activeCall == nil else { return }
            var peer = SignalAddress.from(threadId: signal.thread)
            if !signal.senderName.isEmpty,
               signal.senderName != "Unknown",
               signal.senderName != String(signal.sender.prefix(8)) {
                peer.displayName = signal.senderName
            }
            let nativeAlreadyConnected = nativeStates[signal.callId] == "connected"
            let record = CallRecord(
                conversationId: signal.thread,
                direction: .incoming,
                mediaType: signal.mediaType == "video" ? .video : .voice,
                state: nativeAlreadyConnected ? .active : .ringing,
                startTime: Date(),
                connectTime: nativeAlreadyConnected ? Date() : nil,
                remotePeer: peer
            )
            nativeIDByRecord[record.id] = signal.callId
            recordIDByNativeID[signal.callId] = record.id
            if nativeStates[signal.callId] == "ringing" {
                nativeReadyIDs.insert(signal.callId)
            }
            finishedNativeIDs.remove(signal.callId)
            let call = ActiveCall(callRecord: record)
            activeCall = call
            if nativeAlreadyConnected {
                onActiveCallChanged?(call)
            } else {
                onIncomingCallChanged?(call)
            }
        case .answer:
            // The native state machine consumes the answer. Keep the UI in a
            // connecting state until its ICE/DTLS state transition arrives.
            updateState(for: signal.callId, to: .connecting)
        case .ice:
            break
        case .hangup:
            if let id = recordIDByNativeID[signal.callId],
               let call = activeCall,
               call.callRecord.id == id,
               call.callRecord.conversationId == signal.thread,
               nativeIDByRecord[id] == signal.callId {
                requestRemoteFinish(call, reason: .remoteHangup)
            }
        case .busy:
            if let id = recordIDByNativeID[signal.callId],
               let call = activeCall,
               call.callRecord.id == id,
               call.callRecord.conversationId == signal.thread,
               nativeIDByRecord[id] == signal.callId {
                requestRemoteFinish(call, reason: .declined)
            }
        }
    }

    private func receive(_ event: CallStateEvent) {
        guard rustCore != nil else { return }
        nativeStates[event.callId] = event.state
        Log.info("call UI: native state \(event.state) for \(event.callId)")
        guard let recordID = recordIDByNativeID[event.callId],
              var call = activeCall,
              call.callRecord.id == recordID else { return }
        if finishedNativeIDs.contains(event.callId) { return }

        switch event.state {
        case "incoming":
            if call.callRecord.direction == .incoming {
                call.callRecord.state = .ringing
                activeCall = call
                onIncomingCallChanged?(call)
            } else {
                // A glare/re-offer must not replace an outgoing call with an
                // inbound-call overlay.
                call.callRecord.state = .dialing
                activeCall = call
                onActiveCallChanged?(call)
            }
        case "outgoing":
            call.callRecord.state = .dialing
            activeCall = call
            onActiveCallChanged?(call)
        case "ringing":
            nativeReadyIDs.insert(event.callId)
            if call.callRecord.direction == .incoming {
                if pendingAcceptIDs.contains(event.callId) {
                    // The user already tapped Answer. Do not bring the incoming
                    // overlay back if the native ringing callback races the
                    // accept request.
                    call.callRecord.state = .connecting
                    activeCall = call
                    onIncomingCallChanged?(nil)
                    onActiveCallChanged?(call)
                    performAccept(nativeID: event.callId)
                } else {
                    call.callRecord.state = .ringing
                    activeCall = call
                    onIncomingCallChanged?(call)
                }
            } else {
                call.callRecord.state = .dialing
                activeCall = call
                onActiveCallChanged?(call)
            }
        case "connecting":
            call.callRecord.state = .connecting
            activeCall = call
            onActiveCallChanged?(call)
        case "connected":
            nativeReadyIDs.remove(event.callId)
            pendingAcceptIDs.remove(event.callId)
            if pendingRemoteEndReasons.removeValue(forKey: event.callId) != nil {
                Log.info("call UI: connected won remote-end race for native call \(event.callId)")
            }
            call.callRecord.state = .active
            if call.callRecord.connectTime == nil { call.callRecord.connectTime = Date() }
            activeCall = call
            onIncomingCallChanged?(nil)
            onActiveCallChanged?(call)
        case "ended", "ended_local", "ended_remote", "ended_accepted", "ended_declined",
             "ended_busy", "ended_need_permission", "missed", "timeout", "rejected",
             "busy", "glare", "recall", "failed", "signaling_failed", "connection_failed",
             "dropped", "disconnected", "server_disconnected", "denied", "concluded":
            finish(call, reason: reason(for: event.state))
        default:
            break
        }
    }

    private func requestRemoteFinish(_ call: ActiveCall, reason: CallEndReason) {
        guard let nativeID = nativeIDByRecord[call.callRecord.id],
              !pendingRemoteEndReasons.keys.contains(nativeID) else { return }

        pendingRemoteEndReasons[nativeID] = reason
        var ending = call
        ending.callRecord.state = .ending
        activeCall = ending
        onIncomingCallChanged?(nil)
        onActiveCallChanged?(ending)
        Log.info("call UI: remote end received; waiting for native conclusion for \(nativeID)")

        let recordID = call.callRecord.id
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard let self,
                  let reason = self.pendingRemoteEndReasons[nativeID],
                  let current = self.activeCall,
                  current.callRecord.id == recordID else { return }
            self.finish(current, reason: reason)
        }
    }

    private func updateState(for nativeID: UInt64, to state: CallState) {
        guard let recordID = recordIDByNativeID[nativeID],
              var call = activeCall,
              call.callRecord.id == recordID else { return }
        call.callRecord.state = state
        activeCall = call
        onActiveCallChanged?(call)
    }

    private func finish(_ call: ActiveCall, reason: CallEndReason) {
        guard let nativeID = nativeIDByRecord[call.callRecord.id] else { return }
        guard !finishedNativeIDs.contains(nativeID) else { return }
        finishedNativeIDs.insert(nativeID)
        nativeReadyIDs.remove(nativeID)
        nativeStates.removeValue(forKey: nativeID)
        pendingAcceptIDs.remove(nativeID)
        pendingRemoteEndReasons.removeValue(forKey: nativeID)
        nativeIDByRecord.removeValue(forKey: call.callRecord.id)
        recordIDByNativeID.removeValue(forKey: nativeID)

        var record = call.callRecord
        record.state = .ended
        record.endReason = reason
        record.endTime = record.endTime ?? Date()
        callHistory.append(record)
        activeCall = nil
        onIncomingCallChanged?(nil)
        onActiveCallChanged?(nil)
    }

    private func reason(for state: String) -> CallEndReason {
        switch state {
        case "ended_local": return .localHangup
        case "ended_remote": return .remoteHangup
        case "ended_accepted": return .remoteHangup
        case "ended_declined", "rejected", "busy", "ended_busy": return .declined
        case "missed", "timeout": return .timeout
        case "no_answer": return .noAnswer
        default: return .failed
        }
    }
}

public enum CallError: Error, LocalizedError {
    case alreadyInCall
    case noActiveCall
    case signalingFailed(String)
    case microphonePermissionDenied
    case ringrtcError(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyInCall: return "Already in a call"
        case .noActiveCall: return "No active call"
        case .signalingFailed(let s): return "Signaling failed: \(s)"
        case .microphonePermissionDenied: return "Microphone permission is required for calls"
        case .ringrtcError(let s): return "RingRTC error: \(s)"
        }
    }
}

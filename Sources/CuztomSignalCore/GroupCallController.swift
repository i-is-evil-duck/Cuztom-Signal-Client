import Foundation
import AVFoundation

/// A group call as the user sees it.
///
/// `phase` is the honest summary: it never reports `connected` unless the
/// native engine said so, and it distinguishes "still trying" from "gave up" so
/// the UI can show a spinner rather than a lie.
public struct GroupCallState: Sendable, Equatable, Identifiable {
    public enum Phase: String, Sendable, Equatable {
        /// A client exists and the SFU has not yet admitted it.
        case connecting
        /// The SFU admitted the client and media is flowing.
        case connected
        /// The call ended for a reason worth showing.
        case ended
        /// The call could not proceed. `failure` says why.
        case failed
    }

    public let id: UUID
    /// The ZK group identifier, hex.
    public let groupIdHex: String
    /// The group's master key hex, which is what a group thread id is made of.
    public let masterKeyHex: String
    /// Human-facing group name, when the host knows one.
    public var title: String
    public var phase: Phase
    /// Why the call failed or ended, in words safe to show.
    public var failure: String?
    /// `true` when this device placed the call rather than receiving it.
    public let isOutgoing: Bool
    /// Whether this device's microphone is currently muted in the call.
    ///
    /// Defaults to unmuted because the call path unmutes as soon as a client
    /// exists, before the join. Presenting the control any other way would show
    /// a microphone as off that the call has already been told is on.
    public var isMuted: Bool
    /// Whether this device's camera is currently off.
    ///
    /// Off by default: the camera is never started for a call that did not ask
    /// for video, and a control implying otherwise would be claiming a capability
    /// the call is not using.
    public var isCameraOff: Bool
    /// Whether audio from another participant is arriving.
    ///
    /// `nil` until the first audio level report arrives, which is different from
    /// `false`: not yet measured is not the same as measured and nothing came.
    public var isReceivingAudio: Bool?

    public init(
        id: UUID,
        groupIdHex: String,
        masterKeyHex: String,
        title: String,
        phase: Phase,
        failure: String? = nil,
        isOutgoing: Bool,
        isMuted: Bool = false,
        isCameraOff: Bool = true,
        isReceivingAudio: Bool? = nil
    ) {
        self.id = id
        self.groupIdHex = groupIdHex
        self.masterKeyHex = masterKeyHex
        self.title = title
        self.phase = phase
        self.failure = failure
        self.isOutgoing = isOutgoing
        self.isMuted = isMuted
        self.isCameraOff = isCameraOff
        self.isReceivingAudio = isReceivingAudio
    }
}

/// An inbound group call signal, decoded from the receive stream.
public struct GroupCallSignalEvent: Sendable, Decodable, Equatable {
    public var sender: String
    public var senderDeviceId: UInt32
    /// The ZK group identifier, hex. `nil` when the payload did not carry one,
    /// in which case the group cannot be identified and nothing is joined.
    public var groupIdHex: String?
    public var immediate: Bool
    public var timestamp: UInt64

    private enum CodingKeys: String, CodingKey {
        case sender, immediate
        case senderDeviceId = "sender_device_id"
        case groupIdHex = "group_id"
        case timestamp = "ts"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sender = try c.decode(String.self, forKey: .sender)
        senderDeviceId = try c.decodeIfPresent(UInt32.self, forKey: .senderDeviceId) ?? 1
        groupIdHex = try c.decodeIfPresent(String.self, forKey: .groupIdHex)
        immediate = try c.decodeIfPresent(Bool.self, forKey: .immediate) ?? false
        timestamp = try c.decodeIfPresent(UInt64.self, forKey: .timestamp) ?? 0
    }

    public init(
        sender: String,
        senderDeviceId: UInt32,
        groupIdHex: String?,
        immediate: Bool,
        timestamp: UInt64
    ) {
        self.sender = sender
        self.senderDeviceId = senderDeviceId
        self.groupIdHex = groupIdHex
        self.immediate = immediate
        self.timestamp = timestamp
    }
}

/// The native group-call operations the controller needs.
///
/// Kept as a seam so the orchestration (proof, roster, SFU HTTP) is testable
/// without booting RingRTC or reaching the CDN. The whole point of this
/// controller is the sequence, and the sequence is where the bugs live.
public protocol GroupCallNativeControlling: AnyObject, Sendable {
    var onGroupCallUpdate: ((RustCoreService.GroupCallUpdate) -> Void)? { get set }
    var onHTTPRequest: ((RustCoreService.PendingHTTPRequest) -> Void)? { get set }
    func groupCallGroupId(masterKeyHex: String) async throws -> String
    func groupCallMemberIdentities(
        masterKeyHex: String,
        memberAciUUIDs: [String]
    ) async throws -> [RustCoreService.GroupMember]
    func groupCallProofAuthorization(groupIdHex: String) async throws -> String
    func startGroupCall(
        groupIdHex: String,
        sfuURL: String?
    ) async throws -> RustCoreService.GroupCallHandle
    func joinGroupCall(_ call: RustCoreService.GroupCallHandle) async throws
    func leaveGroupCall(_ call: RustCoreService.GroupCallHandle) async throws
    func endGroupCall(_ call: RustCoreService.GroupCallHandle) async throws
    func groupCallSetMembershipProof(clientId: UInt32, token: [UInt8]) async throws

    /// Say whether this device's microphone is muted.
    ///
    /// Required, not cosmetic: RingRTC starts a group call with the audio-muted
    /// heartbeat unset and reads that as muted, so a controller that never says
    /// otherwise is a participant the rest of the call believes has no
    /// microphone.
    func groupCallSetAudioMuted(clientId: UInt32, muted: Bool) async throws

    /// Say whether this device's camera is off. Separate from the audio flag so
    /// toggling one never has to restate the other.
    func groupCallSetVideoMuted(clientId: UInt32, muted: Bool) async throws

    /// Open or close the microphone. Not the same thing as unmuting, and not a
    /// substitute for it: this is the audio device, that is what the call is told.
    func setMicrophoneWarmup(_ enabled: Bool) async throws
    func groupCallSetGroupMembers(
        clientId: UInt32,
        members: [(userId: [UInt8], memberId: [UInt8])]
    ) async throws
    func deliverHTTPResponse(requestId: UInt32, status: Int?, body: [UInt8]) async throws
}

extension RustCoreService: GroupCallNativeControlling {}

/// Coordinates a group call: joins, answers RingRTC's proof request, supplies
/// the roster, and performs the SFU's HTTP requests on its behalf.
///
/// The order is not negotiable and is the reason this class exists:
///
/// 1. `join` raises `request_membership_proof` and **blocks** the SFU join until
///    a proof is presented. Nothing else about the call matters until then.
/// 2. The proof is a ZK credential, so it cannot be fabricated. If the service
///    issued none for today, the call fails. It does not join "unverified" and it
///    does not report success.
/// 3. `request_group_members` supplies the roster the SFU needs to attribute
///    call traffic. Without it a call connects but nobody can be identified.
/// 4. The SFU issues its HTTP requests as events and stalls until each is
///    answered by request id. A request that is never answered hangs the call,
///    so failures are answered with status 0 rather than dropped.
@MainActor
public final class GroupCallController: ObservableObject {
    public static let shared = GroupCallController()

    @Published public private(set) var current: GroupCallState?

    /// Performs the CDN redemption that turns a proof into a call token.
    public protocol ProofRedeeming: Sendable {
        /// The CDN hosts the service configuration declares, in its order.
        ///
        /// Supplied by the host rather than hardcoded here: the host owns the
        /// native service, and a CDN host baked into this class is wrong on
        /// staging and fails as an unreachable endpoint rather than as a
        /// configuration mistake.
        func cdnBaseURLs() async throws -> [URL]

        func fetchToken(
            cdnBaseURL: URL,
            authorization: String,
            groupIdHex: String
        ) async throws -> GroupCallProofService.Proof
    }

    /// Performs the SFU's own HTTP requests. Separate from the CDN redemption
    /// because they are different endpoints with different failure handling.
    public protocol HTTPPerforming: Sendable {
        func perform(_ request: RustCoreService.PendingHTTPRequest) async throws -> (status: Int, body: [UInt8])
    }

    /// Performs SFU requests through the native core.
    ///
    /// Not a `URLSession`. The SFU serves a certificate from Signal's own
    /// authority rather than the system roots — `sfu.voip.signal.org` presents
    /// `O=Signal Messenger, LLC` with `verify error:num=19, self-signed
    /// certificate in certificate chain` — so `URLSession` refuses the connection
    /// at the TLS layer. That arrives here as an opaque transport error with no
    /// status and no usable description, which is why the previous version of
    /// this reported "the call could not be completed" against a call that was
    /// waiting on a perfectly reachable server.
    ///
    /// The native core is already built with the service configuration's
    /// certificate authority, which is the same reason the group token redemption
    /// is native.
    private struct NativeHTTP: HTTPPerforming {
        /// The live core. Injected rather than reached for globally, so the
        /// controller keeps the same shape in tests and in the app.
        let service: RustCoreService

        func perform(
            _ request: RustCoreService.PendingHTTPRequest
        ) async throws -> (status: Int, body: [UInt8]) {
            let result = try await service.performSFUHTTPRequest(
                method: request.method,
                url: request.url,
                // `PendingHTTPRequest.headers` is a dictionary, so header order is
                // not preserved and a repeated name would already have been
                // collapsed before this point. Order is not significant to the
                // SFU; the pairing is.
                headers: request.headers.map { ($0.key, $0.value) },
                body: request.body ?? []
            )
            // A nil status means the request could not be performed at all, which
            // RingRTC distinguishes from an HTTP error status. Reported as 0,
            // which is the value `core_cmd_http_response` already documents for
            // exactly this case.
            return (result.status ?? 0, result.body)
        }
    }

    /// Somebody is calling a group and the user has not answered yet.
    ///
    /// The title is resolved by the controller when the ring arrives, because the
    /// controller owns the roster and a view cannot await while building a body.
    /// It may be `nil` when the group cannot be resolved — a ring for a group this
    /// device is not in is not answerable anyway, and naming it wrongly would be
    /// worse than saying "Group call".
    public struct GroupCallRing: Sendable, Equatable {
        public let groupIdHex: String
        public let ringId: Int64?
        /// The ringer's service id, raw hex.
        public let senderIdHex: String?
        public var title: String?
    }

    /// One in-flight group call's private bookkeeping.
    private struct Session {
        let stateID: UUID
        let handle: RustCoreService.GroupCallHandle
        let masterKeyHex: String
        var memberACIs: [String]
        var title: String
        let isOutgoing: Bool
        /// Set once a proof has been presented, so a repeated request does not
        /// redeem a second token for the same join.
        var proofPresented = false
        /// Set once the roster has been supplied, for the same reason.
        var membersPresented = false
    }

    private var bridge: (any GroupCallNativeControlling)?
    private let proofService: GroupCallProofService
    private let redeemer: any ProofRedeeming
    /// Replaced in `configure` when the caller did not inject one, so the SFU path
    /// lands on the live core rather than a second one.
    private var http: any HTTPPerforming
    private let sfuURL: String?
    /// Resolves a group's title and membership. Injected so the controller does
    /// not need the whole app model.
    private let roster: any GroupRosterProviding

    private var session: Session?
    private var trackedTasks: [String: Task<Void, Never>] = [:]
    /// An incoming group call awaiting the user. Published so the UI can show it,
    /// and distinct from `current`, which is a call we are already in.
    @Published public private(set) var incoming: GroupCallRing?

    /// Called whenever `incoming` changes, including when it clears.
    ///
    /// Exists because this controller is a Combine `ObservableObject` while the
    /// view model is Swift `@Observable`, and a computed property reading
    /// `incoming` through the controller registers no observation dependency at
    /// all. The ring arrived, `incoming` was set, and the banner never appeared —
    /// the view was never told to re-read. A host that mirrors this into its own
    /// observable state gets the update; one that reads it as a property does not.
    public var onIncomingRingChanged: ((GroupCallRing?) -> Void)?

    /// The single place `incoming` changes, so the change cannot be missed.
    private func setIncoming(_ ring: GroupCallRing?) {
        guard incoming != ring else { return }
        incoming = ring
        onIncomingRingChanged?(ring)
    }
    /// Invalidates callbacks and in-flight work across configure/reset so a late
    /// callback from a retired bridge cannot mutate a new call's state.
    private var lifecycleGeneration = 0
    /// Set when the caller supplied an `HTTPPerforming` directly, so `configure`
    /// does not replace it. A test fake must survive `configure`.
    private let httpIsInjected: Bool

    public init(
        proofService: GroupCallProofService = GroupCallProofService(),
        sfuURL: String? = nil,
        roster: any GroupRosterProviding = EmptyGroupRoster(),
        redeemer: (any ProofRedeeming)? = nil,
        service: RustCoreService? = nil
    ) {
        self.proofService = proofService
        self.redeemer = redeemer ?? proofService
        // A service given here wins. Otherwise the bridge supplies one in
        // `configure`, because using a default-constructed `RustCoreService`
        // instead would stand up a *second* native core against the same
        // database and the same global sync-control slot. That is visible as an
        // extra Keychain passphrase read at the moment the first SFU request is
        // made, and it is a hazard rather than a waste.
        if let service {
            self.http = NativeHTTP(service: service)
            self.httpIsInjected = true
        } else {
            self.http = NativeHTTP(service: RustCoreService())
            self.httpIsInjected = false
        }
        self.sfuURL = sfuURL
        self.roster = roster
    }

    init(
        bridge: any GroupCallNativeControlling,
        proofService: GroupCallProofService = GroupCallProofService(),
        redeemer: any ProofRedeeming,
        http: any HTTPPerforming,
        sfuURL: String? = nil,
        roster: any GroupRosterProviding = EmptyGroupRoster()
    ) {
        self.bridge = bridge
        self.proofService = proofService
        self.redeemer = redeemer
        self.http = http
        self.httpIsInjected = true
        self.sfuURL = sfuURL
        self.roster = roster
    }

    // MARK: - Configuration

    public func configure(with bridge: any GroupCallNativeControlling) {
        lifecycleGeneration += 1
        cancelTrackedTasks()
        self.bridge?.onGroupCallUpdate = nil
        self.bridge?.onHTTPRequest = nil
        self.bridge = bridge
        // The SFU path must run on the same core as the rest of the call. Without
        // this, a controller built by the public init would perform SFU requests
        // on a default-constructed service, standing up a second native core
        // against the same database and the same global sync-control slot.
        if !httpIsInjected, let service = bridge as? RustCoreService {
            self.http = NativeHTTP(service: service)
        }
        let generation = lifecycleGeneration

        bridge.onGroupCallUpdate = { [weak self] update in
            Task { @MainActor [weak self] in
                guard let self, self.lifecycleGeneration == generation else { return }
                self.receive(update)
            }
        }
        bridge.onHTTPRequest = { [weak self] request in
            Task { @MainActor [weak self] in
                guard let self, self.lifecycleGeneration == generation else {
                    // The request still has to be answered or the native call
                    // stalls forever, but there is no live session to attribute
                    // it to, so it is reported as a transport failure.
                    try? await bridge.deliverHTTPResponse(
                        requestId: request.requestId,
                        status: nil,
                        body: []
                    )
                    return
                }
                await self.performSFURequest(request)
            }
        }
    }

    /// Drop all group call state. Native clients are torn down on logout and
    /// relink, so a call must never survive an account boundary.
    public func reset() {
        lifecycleGeneration += 1
        cancelTrackedTasks()
        // A prepared-but-unanswered client is a live native client, so it is
        // released like any other. Leaving it would keep the group occupied and
        // make the next call for that group fail as `Client already exists`.
        if let prepared = pendingInbound {
            let handle = prepared.handle
            Task { [bridge] in try? await bridge?.endGroupCall(handle) }
        }
        pendingInbound = nil
        if let bridge, let session {
            let handle = session.handle
            // Best effort: the native teardown path already refuses untracked
            // ids, and the call is being abandoned either way.
            Task { try? await bridge.endGroupCall(handle) }
        }
        session = nil
        current = nil
        setIncoming(nil)
        self.bridge?.onGroupCallUpdate = nil
        self.bridge?.onHTTPRequest = nil
        bridge = nil
    }

    public func resetAndAwait() async {
        reset()
        // Cancelled tasks are awaited so a test can rely on nothing still running.
        for task in trackedTasks.values { _ = await task.value }
        trackedTasks.removeAll()
    }

    // MARK: - Actions

    /// Place a call to a group.
    ///
    /// The group is identified by its master key, which is what a group thread
    /// id is made of. The ZK identifier RingRTC keys the room on is derived
    /// natively, so the host never guesses it.
    @discardableResult
    public func startCall(masterKeyHex: String, title: String? = nil) async throws -> GroupCallState {
        guard let bridge else {
            throw SignalError.network("group calls are not configured")
        }
        guard session == nil else {
            // One call at a time. A second concurrent group call is a UI bug, and
            // silently replacing the first would leave a native client running.
            throw SignalError.network("a group call is already in progress")
        }
        // Before anything is created, so a refusal costs nothing. A group call
        // that joins with no microphone is a call nobody can hear.
        try await ensureMicrophonePermission()
        let key = masterKeyHex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw SignalError.network("group call needs a group master key")
        }
        let groupIdHex = try await bridge.groupCallGroupId(masterKeyHex: key)
        Log.info("[group-call] step=group-id-derived group=\(groupIdHex.prefix(8))…")
        let members = await primeRoster(masterKeyHex: key)
        let resolvedTitle = title ?? roster.title(masterKeyHex: key)
        let handle = try await bridge.startGroupCall(groupIdHex: groupIdHex, sfuURL: sfuURL)
        Log.info("[group-call] step=client-created client=\(handle.clientId)")

        let stateID = UUID()
        session = Session(
            stateID: stateID,
            handle: handle,
            masterKeyHex: key,
            memberACIs: members,
            title: resolvedTitle,
            isOutgoing: true
        )
        current = GroupCallState(
            id: stateID,
            groupIdHex: groupIdHex,
            masterKeyHex: key,
            title: resolvedTitle,
            phase: .connecting,
            isOutgoing: true
        )
        // Joining is what raises the membership-proof request. The SFU join is
        // blocked until a proof is presented, so this must happen now.
        // Before the join, so the very first heartbeat already says the
        // microphone is live. RingRTC's default is muted and nothing else in this
        // path would ever correct it.
        // The microphone has to be opened before anything can be transmitted.
        // This is the audio device, not the mute flag: the call below is told the
        // microphone is unmuted either way, and both are true at once.
        await openMicrophone()
        await setAudioMuted(false, clientId: handle.clientId)
        // The camera is stated too, even though leaving it unset happens to read
        // as off. Relying on an unset-means-muted default is the same assumption
        // that made the microphone wrong, and Signal's own client sets both flags
        // here for the same reason.
        await setVideoMuted(true, clientId: handle.clientId)
        try await bridge.joinGroupCall(handle)
        Log.info("[group-call] step=join-requested client=\(handle.clientId)")
        return current ?? GroupCallState(
            id: stateID,
            groupIdHex: groupIdHex,
            masterKeyHex: key,
            title: resolvedTitle,
            phase: .connecting,
            isOutgoing: true
        )
    }

    /// Join a group call somebody else started.
    ///
    /// RingRTC drops signaling for a group it has no client for, so a client has
    /// to exist before the call can be received. The group id comes from the
    /// inbound payload; without one nothing is joined, because guessing would
    /// create a client for a room that cannot exist.
    ///
    /// **A signal for the call already in progress is not a new call.** The native
    /// side has already handed the payload to the live RingRTC client before this
    /// event exists, so everything arriving here has been delivered once. Starting
    /// a client for it as well tore the live call down and rebuilt it - once per
    /// inbound signal, which for an established call is routine traffic, so a
    /// connected call never stopped resetting itself. It showed as a client id
    /// climbing through 2, 3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, each one
    /// re-running the whole join, and as `Client already exists for call` from the
    /// rebuild racing its own predecessor.
    ///
    /// So the only thing that ends a live call here is signaling for a *different*
    /// group, which is what a user joining another call actually looks like.
    public func receive(event: GroupCallSignalEvent) async {
        guard let groupIdHex = event.groupIdHex, !groupIdHex.isEmpty else {
            // Not identifiable, so a client cannot be created for it. With a call
            // live that is expected: RingRTC routes the payload by group id on
            // its own, and several of its messages carry none. Reported, because
            // a signal with no group id and no live call is a real gap.
            if session != nil {
                Log.info("[group-call] inbound signal carried no group id; the live call already has it")
            } else {
                // The native side logs *what* the payload was. Without that, this
                // line was identical for a group call we could not identify and
                // for anything else — and the shape of the group call traffic is
                // the only evidence of whether other members' devices are
                // signalling us at all.
                Log.info("[group-call] inbound signal carried no group id; it is unroutable (see the native shape log)")
            }
            return
        }
        if let live = session {
            if live.handle.groupIdHex.caseInsensitiveCompare(groupIdHex) == .orderedSame {
                // Already delivered natively. Starting anything here would replace
                // a working call with an identical one.
                Log.info("[group-call] inbound signal is for the live call; already delivered natively")
                return
            }
            // A different group: the user has moved to another call, so the first
            // is over. Leaving a native client running would leak an SFU session.
            await leaveActiveCall()
        }
        guard let bridge else { return }
        guard let masterKeyHex = await roster.masterKeyHex(forGroupIdHex: groupIdHex) else {
            // Either this device is not in that group, or the id-to-key map
            // could not be read. Both mean the call is not receivable, and both
            // are reported rather than guessed around.
            Log.error("[group-call] inbound call could not be resolved to a local group")
            return
        }
        do {
            let handle = try await bridge.startGroupCall(groupIdHex: groupIdHex, sfuURL: sfuURL)
            // **Created, not joined.** A client has to exist for RingRTC to route
            // signaling to it, but joining is the user's decision: a call that
            // joins itself the moment a packet arrives is not a call, and it
            // looked exactly like one - the SFU admitted the client, so the app
            // sat saying "Joining the call…" for a call the user had never
            // answered and could not get out of without ending it.
            //
            // It also caused `Client already exists for call`: the client created
            // here was still active when the user answered, and answering created
            // a second one for the same group. So the client is kept here and
            // reused by `answer`.
            pendingInbound = PendingInboundCall(
                groupIdHex: groupIdHex,
                masterKeyHex: masterKeyHex,
                handle: handle
            )
            Log.info(
                "[group-call] inbound signal for \(Self.short(groupIdHex)) prepared a client; waiting to be answered"
            )
        } catch {
            fail("Could not join: \(Self.describe(error))")
        }
    }

    /// Leave the SFU but keep the call, so it can be rejoined.
    public func leave() async {
        guard let bridge, let session else { return }
        do {
            try await bridge.leaveGroupCall(session.handle)
            current?.phase = .ended
        } catch {
            fail("Could not leave: \(Self.describe(error))")
        }
    }

    /// End the call and release the native client.
    public func end() async {
        guard let bridge, let session else {
            current = nil
            await closeMicrophone()
            return
        }
        do {
            try await bridge.endGroupCall(session.handle)
        } catch {
            // The call is going away regardless; the native teardown path also
            // refuses ids it does not track, so this is reported, not retried.
            Log.error("[group-call] end failed: \(Self.describe(error))")
        }
        self.session = nil
        current = nil
        await closeMicrophone()
    }

    private func leaveActiveCall() async {
        if let bridge, let session {
            try? await bridge.endGroupCall(session.handle)
        }
        self.session = nil
        current = nil
        // The user moved to a different call, so this one is over and its
        // microphone is not wanted open. The new call opens it again.
        await closeMicrophone()
    }

    // MARK: - Native callbacks

    private func receive(_ update: RustCoreService.GroupCallUpdate) {
        // A ring belongs to no client, because it arrives before anybody has
        // joined. Handled ahead of the session guard below, which would otherwise
        // discard every ring as a client this controller does not own - and a ring
        // is the one update that legitimately has no client behind it.
        if update.kind == .groupCallRing {
            handleRing(update)
            return
        }
        // The SFU participant count is likewise reported against a request id
        // rather than a client, so it cannot pass the session guard below either.
        if update.kind == .peekResult {
            // RingRTC's own participant count, and the exact input to the
            // send-rate decision that switches audio off when it reads one. A
            // count of one is the reason a call is silent, and it is reported
            // rather than acted on so the silence is explained instead of
            // merely observed.
            Log.info(
                "[group-call] sfu reports joined=\(update.joinedCount.map(String.init) ?? "?")"
                    + " identified=\(update.identifiedCount.map(String.init) ?? "?")"
            )
            return
        }
        guard var session, session.handle.clientId == update.clientId else {
            // A client this controller does not own. Retiring one leaves the
            // native side to tear it down, so this is not an error.
            return
        }
        switch update.kind {
        case .groupCallRing:
            // Handled above the session guard, which a ring cannot pass.
            break
        case .audioLevels:
            // Logged by the core and deliberately not allowed to drive the shown
            // state. This build's native layer returns zero for both the captured
            // and the received levels, so a level of zero cannot be told apart
            // from no measurement at all — and reporting "no incoming audio" from
            // it would be a claim rather than an observation.
            Log.info("[group-call] audio levels loudest=\(update.loudestRemoteLevel.map(String.init) ?? "?")")
        case .remoteDevices:
            // Driven instead by the per-device evidence, which this build does
            // populate: a speaker time means audio is genuinely being
            // transmitted, and a media key means we would be able to decrypt it.
            noteRemoteDevices(update)
        case .peekResult:
            // Handled above the session guard, which a client-less update cannot
            // pass.
            break
        case .requestMembershipProof:
            if session.proofPresented {
                // RingRTC asked again after a proof was presented. Answering
                // with a second token would redeem a credential nobody needs.
                return
            }
            self.session = session
            // Supersede any flow still running for this client. A second request
            // while the first is still fetching a credential is normal - the
            // native calls are not cancellable - so the older one is replaced
            // rather than left to race this one to `set_membership_proof`. The
            // returned generation is not used here: the flow captures its own in
            // `presentMembershipProof`, and reading it back from the dictionary
            // would race the next request arriving.
            _ = beginAttempt("proof-\(update.clientId)")
            track("proof-\(update.clientId)") { [weak self] in
                await self?.presentMembershipProof(clientId: update.clientId)
            }
        case .requestGroupMembers:
            if session.membersPresented { return }
            session.membersPresented = true
            self.session = session
            track("members-\(update.clientId)") { [weak self] in
                await self?.presentGroupMembers(clientId: update.clientId)
            }
        case .connectionStateChanged:
            self.session = session
            applyState(update.state ?? update.reason ?? "")
        case .joinStateChanged:
            // Logged under its own name, not as `state:`. These are two different
            // machines and reading them as one is how `Joined(…)` ends up looking
            // like a connection phase it is not. Only a connection state may change
            // what the user is shown.
            self.session = session
            Log.info("[group-call] join: \(update.state ?? update.reason ?? "unspecified")")
        case .ended:
            self.session = session
            Log.info("[group-call] native end: \(Self.endReasonPhrase(update.reason))")
            endFromNative(reason: update.reason)
        case .reactions, .raisedHands, .speechEvent, .remoteMute, .observedRemoteMute:
            // Reactions and speaking indicators need a participant roster
            // mapping that the SFU has not given us yet. They are not surfaced
            // rather than shown against the wrong people.
            break
        @unknown default:
            break
        }
    }

    // MARK: - Local media

    /// Turn this device's microphone on or off in the live call.
    ///
    /// The flag is only flipped once the core has confirmed it, so the control
    /// never claims a state the call has not been told about. A failure leaves
    /// the previous state in place and says so, because a button that silently
    /// does nothing is worse than one that reports it could not.
    public func setMuted(_ muted: Bool) async {
        guard let bridge, let session, var call = current else { return }
        do {
            try await bridge.groupCallSetAudioMuted(clientId: session.handle.clientId, muted: muted)
            call.isMuted = muted
            current = call
        } catch {
            Log.error("[group-call] could not \(muted ? "mute" : "unmute"): \(Self.describe(error))")
        }
    }

    /// Turn this device's camera on or off in the live call.
    ///
    /// The camera is off until something asks for it, so this is the only way it
    /// ever starts: a call does not open a camera the user did not request.
    ///
    /// Turning it **on** asks for camera access first and leaves the camera off if
    /// that is refused. Turning it off needs no permission and cannot fail for
    /// want of one, so a user who never had access can always switch it off.
    public func setCameraOff(_ off: Bool) async {
        guard let bridge, let session, var call = current else { return }
        if !off {
            guard await ensureCameraPermission() else {
                Log.error("[group-call] camera access denied; leaving the camera off")
                call.isCameraOff = true
                current = call
                return
            }
        }
        do {
            try await bridge.groupCallSetVideoMuted(clientId: session.handle.clientId, muted: off)
            call.isCameraOff = off
            current = call
        } catch {
            Log.error("[group-call] could not turn the camera \(off ? "off" : "on"): \(Self.describe(error))")
        }
    }

    /// Note whether audio is arriving from anyone else.
    ///
    /// Driven from the per-device state rather than from audio levels, because
    /// this build's native layer reports no levels and a zero level there is
    /// indistinguishable from a missing measurement. Saying "no incoming audio"
    /// off that basis would be an invention.
    ///
    /// What can be claimed:
    /// - somebody has been heard speaking, so audio is arriving: `true`
    /// - there are other participants and not one has sent a media key, so
    ///   nothing they send could be decrypted: `false`
    /// - anything else: nothing is claimed at all
    ///
    /// A call where everyone is simply quiet is the third case, not the second.
    private func noteRemoteDevices(_ update: RustCoreService.GroupCallUpdate) {
        guard var call = current,
              let deviceCount = update.deviceCount,
              let withKeys = update.devicesWithMediaKeys,
              let spoke = update.devicesThatSpoke
        else { return }
        let receiving: Bool?
        if spoke > 0 {
            receiving = true
        } else if deviceCount > 0 && withKeys == 0 {
            // Others are here and none of them has sent a key, so nothing they
            // say could be turned back into sound. That is a definite fault, not
            // an absence of one.
            receiving = false
        } else {
            receiving = nil
        }
        guard call.isReceivingAudio != receiving else { return }
        call.isReceivingAudio = receiving
        current = call
    }

    /// Present a membership proof.
    ///
    /// This is the step that unblocks the SFU join. It cannot be skipped or
    /// approximated: the token comes from a ZK credential the service issued, so
    /// there is nothing to fall back to.
    ///
    /// Every step is logged by name but never by value. The authorization string
    /// and the resulting token are both secret, and neither is written anywhere.
    private func presentMembershipProof(clientId: UInt32) async {
        let key = "proof-\(clientId)"
        let generation = beginAttempt(key)
        guard let bridge, let session, session.handle.clientId == clientId else { return }
        do {
            Log.info("[group-call] step=proof-fetch client=\(clientId)")
            let authorization = try await bridge.groupCallProofAuthorization(
                groupIdHex: session.handle.groupIdHex
            )
            if abandonIfSuperseded(key, generation, "proof-fetch") { return }
            Log.info("[group-call] step=proof-redeem client=\(clientId)")
            // The hosts come from the service configuration. Each is tried in
            // the order the service lists them: a host that is simply not
            // serving this endpoint should not end the attempt, but a host that
            // answers with a rejection should, because that is a real answer.
            let bases = try await redeemer.cdnBaseURLs()
            guard !bases.isEmpty else {
                fail("Could not join the call: no call service is configured")
                return
            }
            var proof: GroupCallProofService.Proof?
            var lastFailure: Error?
            for base in bases {
                do {
                    proof = try await redeemer.fetchToken(
                        cdnBaseURL: base,
                        authorization: authorization,
                        groupIdHex: session.handle.groupIdHex
                    )
                    break
                } catch let error as GroupCallProofService.Failure {
                    lastFailure = error
                    // An HTTP status or a malformed body is a real answer from a
                    // host that exists; only transport failures justify the next.
                    switch error {
                    case .transport, .invalidCDNHost:
                        continue
                    default:
                        throw error
                    }
                }
            }
            guard let proof else {
                throw lastFailure ?? GroupCallProofService.Failure.transport(
                    "the call service could not be reached"
                )
            }
            Log.info("[group-call] step=proof-present client=\(clientId) tokenBytes=\(proof.token.count)")
            if abandonIfSuperseded(key, generation, "proof-present") { return }
            guard self.session?.handle.clientId == clientId else {
                // The call ended while the CDN round trip was in flight. The
                // token is dropped rather than handed to a dead client.
                return
            }
            // Enter and return are both logged because this is the call the whole
            // join is waiting on, and a return that never arrives is
            // indistinguishable from a join that never proceeds. Nothing is
            // written about the token.
            Log.info("[group-call] step=proof-deliver-begin client=\(clientId)")
            try await bridge.groupCallSetMembershipProof(clientId: clientId, token: proof.token)
            Log.info("[group-call] step=proof-deliver-end client=\(clientId)")
            self.session?.proofPresented = true
            Log.info("[group-call] step=proof-accepted client=\(clientId)")
        } catch {
            // A cancelled task is this flow being replaced, not the call failing.
            // Reporting it as a failure is how a successful join gets a fabricated
            // reason attached to it.
            if error is CancellationError || Task.isCancelled {
                Log.info("[group-call] step=proof-cancelled client=\(clientId); a newer attempt owns the join")
                return
            }
            if isSuperseded(key, generation) {
                Log.info("[group-call] step=proof-failed-superseded client=\(clientId) error=\(Self.describe(error))")
                return
            }
            fail("Could not join the call: \(Self.describe(error))")
        }
    }

    /// The reason a call reached its end, as a short phrase for the log.
    static func endReasonPhrase(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "unspecified" }
        return raw
    }

    private func presentGroupMembers(clientId: UInt32) async {
        guard let bridge, let session, session.handle.clientId == clientId else { return }
        let identities: [RustCoreService.GroupMember]
        do {
            identities = try await bridge.groupCallMemberIdentities(
                masterKeyHex: session.masterKeyHex,
                memberAciUUIDs: session.memberACIs
            )
        } catch {
            fail("Could not read the group's members: \(Self.describe(error))")
            return
        }
        Log.info("[group-call] step=members-built client=\(clientId) count=\(identities.count)")
        guard self.session?.handle.clientId == clientId else { return }
        do {
            try await bridge.groupCallSetGroupMembers(
                clientId: clientId,
                members: identities.map { (userId: $0.userId, memberId: $0.memberId) }
            )
            Log.info("[group-call] step=members-sent client=\(clientId)")
        } catch {
            fail("Could not send the group's members: \(Self.describe(error))")
        }
    }

    /// Answer an SFU HTTP request.
    ///
    /// RingRTC stalls until every request is answered, including on failure, so a
    /// request that cannot be performed is answered with status 0 rather than
    /// dropped. Status 0 is how RingRTC is told the request never happened, which
    /// is different from an HTTP error status.
    private func performSFURequest(_ request: RustCoreService.PendingHTTPRequest) async {
        guard let bridge else { return }
        // The method and path are logged; the headers carry the membership proof
        // and are never written.
        Log.info("[group-call] step=sfu-request id=\(request.requestId) \(request.method) \(Self.sanitizedPath(request.url))")
        do {
            let result = try await http.perform(request)
            try await bridge.deliverHTTPResponse(
                requestId: request.requestId,
                status: result.status,
                body: result.body
            )
            let answered = Self.isConferenceGone(result.status)
                ? " status=\(result.status) (conference gone)"
                : " status=\(result.status)"
            Log.info("[group-call] step=sfu-answered id=\(request.requestId)\(answered)")
        } catch {
            Log.error("[group-call] sfu request \(request.requestId) failed: \(Self.describe(error))")
            try? await bridge.deliverHTTPResponse(
                requestId: request.requestId,
                status: nil,
                body: []
            )
            fail("Call service request failed: \(Self.describe(error))")
        }
    }

    /// An incoming group **ring**.
    ///
    /// Not a call and not a call signal: a ring is somebody calling a group, and
    /// it arrives before anyone has joined the SFU. It is the only notification
    /// that can make a device ring at all, because the media key RingRTC produces
    /// on its own needs the other members' demux ids, which only exist once the
    /// call is under way.
    ///
    /// Only `Requested` means somebody is actually calling. The rest are outcomes
    /// — expired, busy, accepted on another device — and showing one of those as
    /// an incoming call would be a call that does not exist.
    private func handleRing(_ update: RustCoreService.GroupCallUpdate) {
        guard let groupIdHex = update.groupIdHex, !groupIdHex.isEmpty else {
            Log.error("[group-call] ring named no group; nothing to show")
            return
        }
        let outcome = update.ringUpdate ?? "unknown"
        guard outcome == "Requested" else {
            Log.info("[group-call] ring for \(Self.short(groupIdHex)) was \(outcome); not an incoming call")
            return
        }
        if session != nil {
            // Already in a call for this group. A second ring is not a second
            // call, and replacing a live one would tear it down.
            Log.info("[group-call] ring for the call already in progress; ignored")
            return
        }
        Log.info(
            "[group-call] ring received group=\(Self.short(groupIdHex)) sender=\(update.senderIdHex ?? "?") ringId=\(update.ringId.map(String.init) ?? "?")"
        )
        // Surfaced as an incoming call. The client is not created here: joining
        // needs a membership proof, and creating one on a ring would start an SFU
        // session for a call the user may never accept.
        setIncoming(
            GroupCallRing(
                groupIdHex: groupIdHex,
                ringId: update.ringId,
                senderIdHex: update.senderIdHex,
                title: nil
            )
        )
        // The title is resolved after the banner appears rather than delaying it:
        // the roster lookup is async, and a ring that shows up a moment later with
        // the right name is better than one that waits on a lookup.
        let groupId = groupIdHex
        Task { @MainActor [weak self] in
            guard let self,
                  let masterKey = await self.roster.masterKeyHex(forGroupIdHex: groupId),
                  self.incoming?.groupIdHex == groupId
            else { return }
            if var ring = self.incoming {
                ring.title = self.roster.title(masterKeyHex: masterKey)
                self.setIncoming(ring)
            }
        }
    }

    /// Load a group's roster, and say what came back.
    ///
    /// The roster is the member map the SFU needs in order to attribute this
    /// client and to encrypt media towards anyone. A call joined without one
    /// connects and is unusable, so the count is logged and a genuinely empty
    /// roster is reported: the SFU cannot attribute *anybody* in a call like that,
    /// and peers describe such a client as malfunctioning.
    ///
    /// A failure to load is not fatal. The call can still connect, and refusing
    /// would turn a degraded call into no call at all — but it is stated, because
    /// the difference between "one member" and "not read" is invisible otherwise.
    @discardableResult
    private func primeRoster(masterKeyHex: String) async -> [String] {
        do {
            let members = try await roster.load(masterKeyHex: masterKeyHex)
            Log.info("[group-call] roster loaded members=\(members.count)")
            if members.isEmpty {
                Log.error(
                    "[group-call] roster for this group is empty; the call will connect with nobody identifiable"
                )
            }
            return members
        } catch {
            Log.error("[group-call] roster could not be loaded: \(Self.describe(error))")
            return roster.members(masterKeyHex: masterKeyHex)
        }
    }

    /// The master key for a group named by identifier.
    ///
    /// A ring names a group by its ZK identifier, which is not what a thread is
    /// keyed on, so anything that wants to label the call — a title, a
    /// conversation — has to go through this rather than build an id itself.
    public func masterKeyHex(forGroupIdHex groupIdHex: String) async -> String? {
        await roster.masterKeyHex(forGroupIdHex: groupIdHex)
    }

    /// Ask for the microphone, before a call that would need it is created.
    ///
    /// The 1:1 path has always done this and the group path did not, so a group
    /// call opened a peer connection and joined the SFU with no microphone access
    /// at all: no prompt, no audio, and peers reporting "can't receive audio and
    /// video from this client". Every step of the call succeeded and the one that
    /// actually carries a voice did not happen.
    ///
    /// Asked *before* the client is created rather than at first capture, because
    /// RingRTC disables recording while it believes it is the only device in the
    /// call — `set_audio_recording_enabled(false)` — so capture may not begin
    /// until long after a prompt would be useful, and a permission never asked
    /// for is a permission never granted.
    ///
    /// A denial stops the call rather than producing a silent one. Joining an SFU
    /// conference with no audio is indistinguishable, to everyone else, from a
    /// broken client, and that is worse than not joining.
    private func ensureMicrophonePermission() async throws {
        if let override = microphonePermissionOverride {
            guard await override() else { throw SignalError.unsupported("microphone access was denied") }
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { value in
                    continuation.resume(returning: value)
                }
            }
            guard granted else { throw SignalError.unsupported("microphone access was denied") }
        case .denied, .restricted:
            throw SignalError.unsupported("microphone access was denied")
        @unknown default:
            throw SignalError.unsupported("microphone access was denied")
        }
    }

    /// Test seam: replaces the AVFoundation microphone prompt so the group call
    /// path can be exercised without a device or TCC approval.
    var microphonePermissionOverride: (@Sendable () async -> Bool)?

    /// Test seam: the same for the camera.
    var cameraPermissionOverride: (@Sendable () async -> Bool)?

    /// Ask for the camera, and only ever at the moment the user turns it on.
    ///
    /// Deliberately not requested alongside the microphone when a call starts.
    /// The microphone is needed for the call to be a call at all, so asking up
    /// front is the only place the prompt cannot be avoided. A camera is not: a
    /// voice call does not need one, and asking for it on every call would train
    /// the user to dismiss the prompt, and would claim a use for the camera that
    /// the call does not have.
    ///
    /// A denial does not end the call. It leaves the camera off and says so, which
    /// is honest: a call that cannot use the camera is still a call, unlike one
    /// that cannot use the microphone.
    private func ensureCameraPermission() async -> Bool {
        if let override = cameraPermissionOverride {
            return await override()
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .video) { value in
                    continuation.resume(returning: value)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    /// Say whether this device's microphone is muted, and report the default.
    ///
    /// Called as soon as a client exists, on every path, because RingRTC's
    /// default is "muted" and a client that never says otherwise is a participant
    /// the rest of the call believes is silent. A failure is reported rather than
    /// fatal: the call is still a call, and a user who cannot unmute can hear
    /// other people.
    @discardableResult
    private func setAudioMuted(_ muted: Bool, clientId: UInt32) async -> Bool {
        guard let bridge else { return false }
        do {
            try await bridge.groupCallSetAudioMuted(clientId: clientId, muted: muted)
            return true
        } catch {
            Log.error("[group-call] could not set audio muted=\(muted): \(Self.describe(error))")
            return false
        }
    }

    /// Open the microphone for a call that is about to transmit.
    ///
    /// Not the same thing as unmuting, and neither substitutes for the other. The
    /// mute flag is what the rest of the call is told; this is whether the audio
    /// device is actually open. RingRTC opens its input only from here, and only
    /// ever once — its `update_recording_device` re-initialises only if it was
    /// already initialised — so a client that never does this selects a
    /// microphone and then transmits nothing.
    ///
    /// The failure mode is why this is not optional. Incoming audio is
    /// initialised separately, so such a client **receives perfectly and
    /// transmits silence** while reporting itself joined, ICE-connected, unmuted,
    /// and holding a media key it has already sent. Every outward signal says the
    /// call is working.
    ///
    /// Reported rather than fatal: a call that cannot transmit is still a call, and
    /// the person on it can still hear everyone else.
    private func openMicrophone() async {
        guard let bridge else { return }
        do {
            try await bridge.setMicrophoneWarmup(true)
        } catch {
            Log.error("[group-call] could not open the microphone: \(Self.describe(error))")
        }
    }

    /// Close the microphone once no call is using it.
    ///
    /// A microphone left open after the call ends is a privacy problem rather than
    /// a resource one, so it is closed wherever a call is torn down.
    private func closeMicrophone() async {
        guard let bridge else { return }
        do {
            try await bridge.setMicrophoneWarmup(false)
        } catch {
            Log.error("[group-call] could not close the microphone: \(Self.describe(error))")
        }
    }

    /// State this device's camera as off, before the join.
    ///
    /// A helper rather than an inline call because the point is that it happens
    /// on *every* path: the camera being off is the safe default anyway, so a
    /// path that forgot this would look fine right up until the first heartbeat,
    /// and then be indistinguishable from a client that never opened a camera.
    private func setVideoMuted(_ muted: Bool, clientId: UInt32) async -> Bool {
        guard let bridge else { return false }
        do {
            try await bridge.groupCallSetVideoMuted(clientId: clientId, muted: muted)
            return true
        } catch {
            Log.error("[group-call] could not set video muted=\(muted): \(Self.describe(error))")
            return false
        }
    }

    /// A client created for an inbound call that has not been answered.    ///
    /// RingRTC drops signaling for a group it has no client for, so one has to
    /// exist before the call can be received. It is kept rather than joined:
    /// joining is the user's decision, and creating a second client for the same
    /// group is refused by RingRTC as `Client already exists for call`.
    private struct PendingInboundCall {
        let groupIdHex: String
        let masterKeyHex: String
        let handle: RustCoreService.GroupCallHandle
    }

    private var pendingInbound: PendingInboundCall?

    /// Answer an incoming group call by joining it.
    ///
    /// The group id comes from the ring, which is the only notification that
    /// names a call before anyone has joined — so this is the one path where the
    /// group is known without the user having picked anything. The rest of the
    /// join is the ordinary one: a client is created, a membership proof is
    /// fetched and redeemed, and the SFU admits it.
    ///
    /// The ring is cleared first, whether or not the join succeeds, so a failed
    /// join does not leave a banner offering a call that has already been tried
    /// and failed.
    public func answer(_ ring: GroupCallRing) async -> GroupCallState? {
        guard let bridge else { return nil }
        // Asked here for the same reason as on the outgoing path, and answering is
        // the last moment it can be asked without the call already being visible
        // to everyone as a participant with no voice. A refusal keeps the ring: the
        // permission is fixable in System Settings and the user is mid-decision,
        // so clearing the banner and leaving the reason in the log would be the
        // worst outcome of the three.
        do {
            try await ensureMicrophonePermission()
        } catch {
            Log.error("[group-call] not answered: \(Self.describe(error))")
            return nil
        }
        guard let masterKeyHex = await roster.masterKeyHex(forGroupIdHex: ring.groupIdHex) else {
            // Either this device is not in the group, or the id map could not be
            // read. The ring is not answerable in that case, and is not guessed
            // around.
            Log.error("[group-call] ring named a group this device is not in; cannot answer")
            setIncoming(nil)
            return nil
        }
        setIncoming(nil)
        // A client already prepared for this group by the inbound signal is
        // reused. RingRTC refuses a second active client for a group as
        // `Client already exists for call`, which is what answering hit every time
        // a call had been signalled before the user answered it.
        let prepared = pendingInbound.flatMap {
            $0.groupIdHex.caseInsensitiveCompare(ring.groupIdHex) == .orderedSame ? $0 : nil
        }
        pendingInbound = nil
        // Primed here for the same reason the outgoing path primes it: without a
        // loaded roster the SFU is given no member map, so it cannot attribute
        // this client or encrypt anything towards it. That is not a cosmetic
        // gap - a call joined with an empty roster connects and is useless, and
        // peers report the client as malfunctioning.
        await primeRoster(masterKeyHex: masterKeyHex)
        Log.info(
            "[group-call] answering ring for \(Self.short(ring.groupIdHex))"
                + (prepared == nil ? " (new client)" : " (reusing the prepared client)")
        )
        do {
            // Not `??` with an autoclosure: the right side is an async call, and
            // an autoclosure cannot await.
            let handle: RustCoreService.GroupCallHandle
            if let prepared {
                handle = prepared.handle
            } else {
                handle = try await bridge.startGroupCall(
                    groupIdHex: ring.groupIdHex,
                    sfuURL: sfuURL
                )
            }
            let stateID = UUID()
            let members = roster.members(masterKeyHex: masterKeyHex)
            let title = roster.title(masterKeyHex: masterKeyHex)
            session = Session(
                stateID: stateID,
                handle: handle,
                masterKeyHex: masterKeyHex,
                memberACIs: members,
                title: title,
                isOutgoing: false
            )
            current = GroupCallState(
                id: stateID,
                groupIdHex: ring.groupIdHex,
                masterKeyHex: masterKeyHex,
                title: title,
                phase: .connecting,
                isOutgoing: false
            )
            // Before the join, so the very first heartbeat already says the
        // microphone is live. RingRTC's default is muted and nothing else in this
        // path would ever correct it.
        // The microphone has to be opened before anything can be transmitted.
        // This is the audio device, not the mute flag: the call below is told the
        // microphone is unmuted either way, and both are true at once.
        await openMicrophone()
        await setAudioMuted(false, clientId: handle.clientId)
        // The camera is stated too, even though leaving it unset happens to read
        // as off. Relying on an unset-means-muted default is the same assumption
        // that made the microphone wrong, and Signal's own client sets both flags
        // here for the same reason.
        await setVideoMuted(true, clientId: handle.clientId)
        try await bridge.joinGroupCall(handle)
            Log.info("[group-call] step=join-requested client=\(handle.clientId) (answered)")
            return current
        } catch {
            fail("Could not join the call: \(Self.describe(error))")
            return nil
        }
    }

    /// Dismiss an incoming call without answering it.
    ///
    /// The ring stays in the caller's hands: this is a local decision not to
    /// answer, not a cancellation, and a cancellation would need the ringer's
    /// `ring_id` echoed back in a message this client does not send.
    public func decline(_ ring: GroupCallRing) {
        Log.info("[group-call] declined ring for \(Self.short(ring.groupIdHex))")
        if incoming?.ringId == ring.ringId { setIncoming(nil) }
    }

    /// A group id, shortened for a log line. Full length is stable, so the
    /// prefix identifies the group without carrying 64 characters per line.
    static func short(_ groupIdHex: String, keep: Int = 8) -> String {
        groupIdHex.count <= keep ? groupIdHex : "\(groupIdHex.prefix(keep))…"
    }

    /// A 404 from the SFU's participants poll means the conference is gone, which
    /// is what a hangup looks like from the other end.
    ///
    /// Named rather than logged inline because it is a fact about the SFU worth
    /// stating. The poll is a heartbeat, and the SFU answers 404 for a conference
    /// that no longer exists — not for a request it could not understand. It
    /// arrives after a hangup, so reading it as a failure would put a spurious
    /// error on a call that ended the way it should.
    static func isConferenceGone(_ status: Int) -> Bool {
        status == 404
    }

    /// Identity of the service the SFU performer will use, for tests.
    ///
    /// Exists so the wiring can be asserted rather than inferred. The failure
    /// being guarded against - a second native core standing up against the same
    /// database - has no other symptom at the point it happens, so there has to
    /// be something to check.
    var sfuServiceIdentifier: ObjectIdentifier? {
        guard let native = http as? NativeHTTP else { return nil }
        return ObjectIdentifier(native.service)
    }

    // MARK: - State

    /// Map a native state name onto what the user is shown.
    ///
    /// Matching is on the whole name, not a substring: RingRTC's states are
    /// `NotConnected`, `Connecting`, `Connected`, and `Reconnecting`, so a
    /// `contains("connected")` test reads `NotConnected` and `Reconnecting` as
    /// connected. A call must never be shown as working when it is not.
    static func phase(forNativeState raw: String) -> GroupCallState.Phase? {
        switch raw {
        case "Connected": return .connected
        case "Connecting", "Reconnecting", "NotConnected": return .connecting
        default:
            // A state this build does not know. Left as-is rather than guessed
            // at, so an unexpected value cannot be shown as a working call.
            return nil
        }
    }

    private func applyState(_ raw: String) {
        Log.info("[group-call] state: \(raw)")
        guard var state = current, let phase = Self.phase(forNativeState: raw) else { return }
        state.phase = phase
        if phase == .connected { state.failure = nil }
        current = state
    }

    private func endFromNative(reason: String?) {
        if var state = current {
            state.phase = .ended
            if let reason, !reason.isEmpty {
                state.failure = reason
            }
            current = state
        }
        session = nil
    }

    private func fail(_ message: String) {
        // Logged unconditionally. A failure that only changes the banner leaves
        // nothing in the log, which is how a call can sit in "connecting" with
        // no evidence anywhere of why it stopped.
        Log.error("[group-call] failed: \(message)")
        guard var state = current else {
            Log.error("[group-call] failed with no active call to report it on")
            return
        }
        state.phase = .failed
        state.failure = message
        current = state
        // The native client is released so a later call starts clean. The call
        // did not connect, so there is nothing to leave gracefully.
        if let bridge, let session {
            let handle = session.handle
            Task { try? await bridge.endGroupCall(handle) }
        }
        session = nil
    }

    private func track(_ key: String, _ body: @escaping @MainActor @Sendable () async -> Void) {
        trackedTasks[key]?.cancel()
        trackedTasks[key] = Task { @MainActor in await body() }
    }

    /// Whether a superseded task is being run, per tracked key.
    ///
    /// `track` cancels the previous `Task`, but cancellation does not reach the
    /// native calls: `groupCallProofAuthorization` and `fetchToken` are foreign
    /// function calls that run to completion whatever the Swift task state is.
    /// A superseded flow therefore finishes normally, and used to report its own
    /// cancellation as a join failure - which is worse than no reporting, because
    /// `CancellationError` has no description and lands on `describe`'s generic
    /// fallback, producing "the call could not be completed" for a call that
    /// might be about to succeed. That is a fabricated reason, in the one place
    /// a real reason is needed.
    ///
    /// A counter rather than a flag: two requests can supersede each other and
    /// come back out of order, and a bool would let an older flow clear a newer
    /// one's flag.
    private var supersededGenerations: [String: UInt64] = [:]

    /// Mark the current attempt for `key` as replaced and return the new
    /// generation. A flow captures this and compares before every step and
    /// before reporting anything.
    private func beginAttempt(_ key: String) -> UInt64 {
        let next = (supersededGenerations[key] ?? 0) &+ 1
        supersededGenerations[key] = next
        return next
    }

    /// True when a newer attempt for `key` has started since `generation` was
    /// issued, meaning this flow's work is redundant and its outcome is not news.
    private func isSuperseded(_ key: String, _ generation: UInt64) -> Bool {
        supersededGenerations[key].map { $0 != generation } ?? false
    }

    /// Stop a superseded flow without reporting a failure.
    ///
    /// Returns true when the caller should return immediately. Logged, because a
    /// silent return here would look exactly like a hang.
    private func abandonIfSuperseded(_ key: String, _ generation: UInt64, _ step: String) -> Bool {
        guard isSuperseded(key, generation) else { return false }
        Log.info("[group-call] step=\(step) superseded; a newer attempt is in flight")
        return true
    }

    private func cancelTrackedTasks() {
        for task in trackedTasks.values { task.cancel() }
        trackedTasks.removeAll()
        supersededGenerations.removeAll()
    }

    /// A request URL reduced to host and path, so an SFU request can be
    /// identified in the log without writing query values, which can carry
    /// identifiers.
    static func sanitizedPath(_ url: String) -> String {
        guard let parsed = URL(string: url), let host = parsed.host else {
            return "<unparsable url>"
        }
        return host + parsed.path
    }

    /// A message safe to put in front of a user.
    ///
    /// Native errors are passed through because they are written for this
    /// purpose. Anything else gets a generic message rather than a description
    /// of an arbitrary error's internals, which could name paths or endpoints.
    public static func describe(_ error: Error) -> String {
        // Cancellation is not a fault and has no description. It is named here
        // rather than falling through, because falling through attributes it to
        // the generic "the call could not be completed" - a fabricated reason
        // attached to a call that may be about to connect. Callers that can tell
        // a cancellation apart should not be reporting one at all, but a stray
        // one must still read as what it is.
        if error is CancellationError {
            return "the attempt was cancelled"
        }
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        // `SignalError` carries a message written for this purpose, and the
        // proof and CDN failures are the ones a user can act on.
        if let signalError = error as? SignalError {
            switch signalError {
            case .network(let message), .crypto(let message), .storage(let message),
                 .unsupported(let message):
                return message
            case .notLinked, .alreadyLinked, .sessionInvalidated:
                return "the account is no longer linked"
            }
        }
        // Anything else could name an endpoint or a path, so it is not shown.
        return "the call could not be completed"
    }
}

extension GroupCallProofService: GroupCallController.ProofRedeeming {
    /// Signal's own CDN root.
    ///
    /// Used only when no native service configuration is available, which in
    /// practice means a test. A live redemption reads the hosts from the service
    /// configuration, because they differ between staging and production.
    public static let fallbackCDNBaseURL = URL(string: "https://cdn.signal.org")!

    public func cdnBaseURLs() async throws -> [URL] {
        [Self.fallbackCDNBaseURL]
    }
}

/// Group membership and titles, which the controller needs but should not own.
public protocol GroupRosterProviding: Sendable {
    /// Member ACI UUIDs for a group, in any order.
    func members(masterKeyHex: String) -> [String]
    /// A display name, or an empty string when unknown.
    func title(masterKeyHex: String) -> String
    /// The master key for a ZK group id, when this device is in that group.
    ///
    /// An inbound call can only be joined by mapping its group id back to a
    /// group on this device. Returning `nil` means the call is not receivable.
    ///
    /// This is `async` because the mapping may need reading from the store on
    /// first use. It cannot be fetched eagerly at startup: the mapping lives
    /// behind the sync loop's live manager, which is not running yet at that
    /// point, so an eager read always fails and inbound calls then stay
    /// unresolvable for the life of the process.
    func masterKeyHex(forGroupIdHex groupIdHex: String) async -> String?

    /// Load the roster for a group, returning the member ACIs.
    ///
    /// Separate from `members` because the two can disagree, and the
    /// disagreement is the whole problem: `members` reads a cache that is empty
    /// until something has loaded it, and a call joined on a cache that was never
    /// filled hands the SFU no member map. It then cannot attribute this client
    /// or encrypt media towards anyone, so the call connects and is unusable, and
    /// peers report the client as malfunctioning.
    ///
    /// Defaults to the cached read, so a roster with nothing to load — a test, or
    /// a host that loads elsewhere — still works and still reports what it has.
    func load(masterKeyHex: String) async throws -> [String]
}

extension GroupRosterProviding {
    public func load(masterKeyHex: String) async throws -> [String] {
        members(masterKeyHex: masterKeyHex)
    }
}

/// A roster that knows nothing, so the controller is usable before the host
/// supplies one. An unknown group yields an empty member list and no title,
/// which fails visibly rather than pretending.
public struct EmptyGroupRoster: GroupRosterProviding {
    public init() {}
    public func members(masterKeyHex: String) -> [String] { [] }
    public func title(masterKeyHex: String) -> String { "" }
    public func masterKeyHex(forGroupIdHex groupIdHex: String) async -> String? { nil }
}

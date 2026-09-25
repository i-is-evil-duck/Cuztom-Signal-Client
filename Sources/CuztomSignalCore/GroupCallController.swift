import Foundation

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

    public init(
        id: UUID,
        groupIdHex: String,
        masterKeyHex: String,
        title: String,
        phase: Phase,
        failure: String? = nil,
        isOutgoing: Bool
    ) {
        self.id = id
        self.groupIdHex = groupIdHex
        self.masterKeyHex = masterKeyHex
        self.title = title
        self.phase = phase
        self.failure = failure
        self.isOutgoing = isOutgoing
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

    private struct LiveHTTP: HTTPPerforming {
        let session: URLSession

        func perform(
            _ request: RustCoreService.PendingHTTPRequest
        ) async throws -> (status: Int, body: [UInt8]) {
            guard let url = URL(string: request.url), url.scheme?.lowercased() == "https" else {
                throw SignalError.network("SFU request URL was not https")
            }
            var urlRequest = URLRequest(url: url)
            urlRequest.httpMethod = request.method
            for (field, value) in request.headers {
                urlRequest.setValue(value, forHTTPHeaderField: field)
            }
            urlRequest.httpBody = request.body.map { Data($0) }
            let (data, response) = try await session.data(for: urlRequest)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (status, [UInt8](data))
        }
    }

    /// The CDN root that redeems membership proofs. Signal's own is
    /// `https://cdn.signal.org`; it is never inferred from the environment.
    public static let defaultCDNBaseURL = URL(string: "https://cdn.signal.org")!

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
    private let http: any HTTPPerforming
    private let cdnBaseURL: URL
    private let sfuURL: String?
    /// Resolves a group's title and membership. Injected so the controller does
    /// not need the whole app model.
    private let roster: any GroupRosterProviding

    private var session: Session?
    private var trackedTasks: [String: Task<Void, Never>] = [:]
    /// Invalidates callbacks and in-flight work across configure/reset so a late
    /// callback from a retired bridge cannot mutate a new call's state.
    private var lifecycleGeneration = 0

    public init(
        proofService: GroupCallProofService = GroupCallProofService(),
        cdnBaseURL: URL = GroupCallController.defaultCDNBaseURL,
        sfuURL: String? = nil,
        roster: any GroupRosterProviding = EmptyGroupRoster()
    ) {
        self.proofService = proofService
        self.redeemer = proofService
        self.http = LiveHTTP(session: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 20
            configuration.httpShouldSetCookies = false
            return URLSession(configuration: configuration)
        }())
        self.cdnBaseURL = cdnBaseURL
        self.sfuURL = sfuURL
        self.roster = roster
    }

    init(
        bridge: any GroupCallNativeControlling,
        proofService: GroupCallProofService = GroupCallProofService(),
        redeemer: any ProofRedeeming,
        http: any HTTPPerforming,
        cdnBaseURL: URL = GroupCallController.defaultCDNBaseURL,
        sfuURL: String? = nil,
        roster: any GroupRosterProviding = EmptyGroupRoster()
    ) {
        self.bridge = bridge
        self.proofService = proofService
        self.redeemer = redeemer
        self.http = http
        self.cdnBaseURL = cdnBaseURL
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
        if let bridge, let session {
            let handle = session.handle
            // Best effort: the native teardown path already refuses untracked
            // ids, and the call is being abandoned either way.
            Task { try? await bridge.endGroupCall(handle) }
        }
        session = nil
        current = nil
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
        let key = masterKeyHex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw SignalError.network("group call needs a group master key")
        }
        let groupIdHex = try await bridge.groupCallGroupId(masterKeyHex: key)
        Log.info("[group-call] step=group-id-derived group=\(groupIdHex.prefix(8))…")
        let members = roster.members(masterKeyHex: key)
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
    public func receive(event: GroupCallSignalEvent) async {
        guard let groupIdHex = event.groupIdHex, !groupIdHex.isEmpty else {
            // Not identifiable, so not receivable. Reported rather than dropped
            // so the user is not left with a ringing group that never appears.
            Log.error("[group-call] inbound signal had no group id; nothing to join")
            return
        }
        if session != nil {
            // A second group call while one is live: end this one and take the
            // newer. The user calling another group means the first is over, and
            // leaving a native client running would leak an SFU session.
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
                groupIdHex: groupIdHex,
                masterKeyHex: masterKeyHex,
                title: title,
                phase: .connecting,
                isOutgoing: false
            )
            try await bridge.joinGroupCall(handle)
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
    }

    private func leaveActiveCall() async {
        if let bridge, let session {
            try? await bridge.endGroupCall(session.handle)
        }
        self.session = nil
        current = nil
    }

    // MARK: - Native callbacks

    private func receive(_ update: RustCoreService.GroupCallUpdate) {
        guard var session, session.handle.clientId == update.clientId else {
            // A client this controller does not own. Retiring one leaves the
            // native side to tear it down, so this is not an error.
            return
        }
        switch update.kind {
        case .requestMembershipProof:
            if session.proofPresented {
                // RingRTC asked again after a proof was presented. Answering
                // with a second token would redeem a credential nobody needs.
                return
            }
            self.session = session
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
        case .connectionStateChanged, .joinStateChanged:
            self.session = session
            applyState(update.state ?? update.reason ?? "")
        case .ended:
            self.session = session
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

    /// Present a membership proof.
    ///
    /// This is the step that unblocks the SFU join. It cannot be skipped or
    /// approximated: the token comes from a ZK credential the service issued, so
    /// there is nothing to fall back to.
    ///
    /// Every step is logged by name but never by value. The authorization string
    /// and the resulting token are both secret, and neither is written anywhere.
    private func presentMembershipProof(clientId: UInt32) async {
        guard let bridge, let session, session.handle.clientId == clientId else { return }
        do {
            Log.info("[group-call] step=proof-fetch client=\(clientId)")
            let authorization = try await bridge.groupCallProofAuthorization(
                groupIdHex: session.handle.groupIdHex
            )
            Log.info("[group-call] step=proof-redeem client=\(clientId)")
            let proof = try await redeemer.fetchToken(
                cdnBaseURL: cdnBaseURL,
                authorization: authorization,
                groupIdHex: session.handle.groupIdHex
            )
            Log.info("[group-call] step=proof-present client=\(clientId) tokenBytes=\(proof.token.count)")
            guard self.session?.handle.clientId == clientId else {
                // The call ended while the CDN round trip was in flight. The
                // token is dropped rather than handed to a dead client.
                return
            }
            try await bridge.groupCallSetMembershipProof(clientId: clientId, token: proof.token)
            self.session?.proofPresented = true
            Log.info("[group-call] step=proof-accepted client=\(clientId)")
        } catch {
            fail("Could not join the call: \(Self.describe(error))")
        }
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
            Log.info("[group-call] step=sfu-answered id=\(request.requestId) status=\(result.status)")
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
        guard var state = current else { return }
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

    private func cancelTrackedTasks() {
        for task in trackedTasks.values { task.cancel() }
        trackedTasks.removeAll()
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

extension GroupCallProofService: GroupCallController.ProofRedeeming {}

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

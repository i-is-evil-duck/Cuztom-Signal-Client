import Foundation
import Testing
@testable import CuztomSignalCore

/// The group-call controller's value is entirely in the *sequence*: join, then
/// answer the proof request, then supply the roster, then perform the SFU's HTTP
/// requests. Each step can succeed while the whole still fails, and a call that
/// cannot connect must never be reported as connected.
///
/// These tests drive the sequence through a fake native bridge, so the ordering
/// and the failure handling are checked without a real SFU.
@Suite("Group call controller")
struct GroupCallControllerTests {
    private static let groupIdHex = String(repeating: "ab", count: 32)
    private static let masterKeyHex = String(repeating: "cd", count: 32)

    // MARK: - Fakes

    /// Records every native call in order, and can be told to fail each one.
    final class FakeBridge: GroupCallNativeControlling, @unchecked Sendable {
        var onGroupCallUpdate: ((RustCoreService.GroupCallUpdate) -> Void)?
        var onHTTPRequest: ((RustCoreService.PendingHTTPRequest) -> Void)?

        private(set) var steps: [String] = []
        var failProof = false
        var failMembers = false
        var failStart = false
        var failEnd = false
        var proofToken: [UInt8] = [0xAA, 0xBB]
        /// Emits the callback sequence a real join produces, in order.
        var raisesProofRequest = true
        var raisesMembersRequest = true
        var nextClientId: UInt32 = 7
        var httpResponses: [UInt32: (Int, [UInt8])] = [:]

        func groupCallGroupId(masterKeyHex: String) async throws -> String {
            steps.append("deriveId")
            return GroupCallControllerTests.groupIdHex
        }

        func groupCallMemberIdentities(
            masterKeyHex: String,
            memberAciUUIDs: [String]
        ) async throws -> [RustCoreService.GroupMember] {
            steps.append("buildMembers(\(memberACIs(memberAciUUIDs)))")
            if failMembers { throw SignalError.crypto("member derivation refused") }
            return memberAciUUIDs.enumerated().map { index, _ in
                RustCoreService.GroupMember(
                    userId: [UInt8](repeating: UInt8(index), count: 16),
                    memberId: [UInt8(index), 0x02]
                )
            }
        }

        func groupCallProofAuthorization(groupIdHex: String) async throws -> String {
            steps.append("authorize")
            if failProof { throw SignalError.crypto("no credential for today") }
            // The shape the CDN layer requires: two hex halves.
            return "\(String(repeating: "11", count: 32)):\(String(repeating: "22", count: 32))"
        }

        func startGroupCall(
            groupIdHex: String,
            sfuURL: String?
        ) async throws -> RustCoreService.GroupCallHandle {
            steps.append("start")
            if failStart { throw SignalError.network("native refused to create a client") }
            return RustCoreService.GroupCallHandle(clientId: nextClientId, groupIdHex: groupIdHex)
        }

        func joinGroupCall(_ call: RustCoreService.GroupCallHandle) async throws {
            steps.append("join")
            // RingRTC raises the proof request from inside join and blocks the
            // SFU join until a proof arrives.
            if raisesProofRequest {
                onGroupCallUpdate?(
                    RustCoreService.GroupCallUpdate(
                        kind: .requestMembershipProof,
                        clientId: call.clientId
                    )
                )
            }
            if raisesMembersRequest {
                onGroupCallUpdate?(
                    RustCoreService.GroupCallUpdate(
                        kind: .requestGroupMembers,
                        clientId: call.clientId
                    )
                )
            }
        }

        func leaveGroupCall(_ call: RustCoreService.GroupCallHandle) async throws {
            steps.append("leave")
        }

        func endGroupCall(_ call: RustCoreService.GroupCallHandle) async throws {
            steps.append("end")
            if failEnd { throw SignalError.network("native refused to end") }
        }

        func groupCallSetMembershipProof(clientId: UInt32, token: [UInt8]) async throws {
            steps.append("presentProof(\(token.count) bytes)")
        }

        static let videoMuteRefused = NSError(
            domain: "FakeBridge", code: 7, userInfo: [NSLocalizedDescriptionKey: "no camera"]
        )
        /// Makes the camera change fail, to check the shown state does not
        /// follow a change that did not happen.
        var failVideoMute = false

        func groupCallSetAudioMuted(clientId: UInt32, muted: Bool) async throws {
            steps.append("setAudioMuted(\(muted))")
        }

        func setMicrophoneWarmup(_ enabled: Bool) async throws {
            steps.append("microphoneWarmup(\(enabled))")
        }

        func groupCallSetVideoMuted(clientId: UInt32, muted: Bool) async throws {
            steps.append("setVideoMuted(\(muted))")
            if failVideoMute { throw FakeBridge.videoMuteRefused }
        }

        func groupCallSetGroupMembers(
            clientId: UInt32,
            members: [(userId: [UInt8], memberId: [UInt8])]
        ) async throws {
            steps.append("presentMembers(\(members.count))")
        }

        func deliverHTTPResponse(requestId: UInt32, status: Int?, body: [UInt8]) async throws {
            steps.append("httpResponse(\(requestId), status: \(status.map(String.init) ?? "none"))")
        }

        func raiseConnectionState(_ state: String, clientId: UInt32) {
            onGroupCallUpdate?(
                RustCoreService.GroupCallUpdate(
                    kind: .connectionStateChanged,
                    clientId: clientId,
                    state: state
                )
            )
        }

        func raiseEnded(clientId: UInt32, reason: String?) {
            onGroupCallUpdate?(
                RustCoreService.GroupCallUpdate(
                    kind: .ended,
                    clientId: clientId,
                    reason: reason
                )
            )
        }

        private func memberACIs(_ values: [String]) -> String {
            values.isEmpty ? "none" : "\(values.count)"
        }
    }

    /// A class so the call count is observable after the fact.
    final class FakeRedeemer: GroupCallController.ProofRedeeming, @unchecked Sendable {
        let token: [UInt8]
        var failure: Error?
        /// Hosts the redeemer offers, in order. Two by default so the retry across
        /// configured hosts is exercised rather than assumed.
        var bases: [URL] = [
            URL(string: "https://cdn-first.example.test")!,
            URL(string: "https://cdn-second.example.test")!,
        ]
        var basesError: Error?
        private(set) var requests = 0
        private(set) var attemptedHosts: [String] = []

        init(token: [UInt8], failure: Error? = nil) {
            self.token = token
            self.failure = failure
        }

        func cdnBaseURLs() async throws -> [URL] {
            if let basesError { throw basesError }
            return bases
        }

        func fetchToken(
            cdnBaseURL: URL,
            authorization: String,
            groupIdHex: String
        ) async throws -> GroupCallProofService.Proof {
            requests += 1
            attemptedHosts.append(cdnBaseURL.host ?? "?")
            if let failure { throw failure }
            #expect(authorization.contains(":"))
            return GroupCallProofService.Proof(groupIdHex: groupIdHex, token: token)
        }
    }

    /// A counter usable from a `@Sendable` closure, which a captured `var` is not.
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func bump() { lock.withLock { count += 1 } }
    }

    /// A class so the call count is observable after the fact.
    final class FakeHTTP: GroupCallController.HTTPPerforming, @unchecked Sendable {
        var status = 200
        var body: [UInt8] = [0x01]
        var failure: Error?
        private(set) var performed = 0

        init(status: Int = 200, body: [UInt8] = [0x01], failure: Error? = nil) {
            self.status = status
            self.body = body
            self.failure = failure
        }

        func perform(
            _ request: RustCoreService.PendingHTTPRequest
        ) async throws -> (status: Int, body: [UInt8]) {
            performed += 1
            if let failure { throw failure }
            return (status, body)
        }
    }

    /// Holds the token fetch open until told otherwise, so a second proof request
    /// can arrive while the first flow is still inside a native call. This is the
    /// shape of the real race: `Task.cancel()` does not reach a foreign call, so
    /// "cancelled" and "still running" are the same thing for as long as the
    /// native call lasts.
    final class GatedRedeemer: GroupCallController.ProofRedeeming, @unchecked Sendable {
        let token: [UInt8]
        private var gate: CheckedContinuation<Void, Never>?
        private(set) var entered = 0

        init(token: [UInt8]) { self.token = token }

        func cdnBaseURLs() async throws -> [URL] {
            [URL(string: "https://cdn-first.example.test")!]
        }

        func fetchToken(
            cdnBaseURL: URL,
            authorization: String,
            groupIdHex: String
        ) async throws -> GroupCallProofService.Proof {
            entered += 1
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                gate = continuation
            }
            return GroupCallProofService.Proof(groupIdHex: groupIdHex, token: token)
        }

        func release() {
            gate?.resume()
            gate = nil
        }
    }

    /// A redeemer that always succeeds, for tests that only need the extra
    /// round trip to not fail.
    final class SlowRedeemer: GroupCallController.ProofRedeeming, @unchecked Sendable {
        let token: [UInt8]
        init(token: [UInt8]) { self.token = token }

        func cdnBaseURLs() async throws -> [URL] {
            [URL(string: "https://cdn-first.example.test")!]
        }

        func fetchToken(
            cdnBaseURL: URL,
            authorization: String,
            groupIdHex: String
        ) async throws -> GroupCallProofService.Proof {
            GroupCallProofService.Proof(groupIdHex: groupIdHex, token: token)
        }
    }

    struct FakeRoster: GroupRosterProviding {
        var memberACIs: [String] = ["11111111-1111-1111-1111-111111111111"]
        var groupTitle = "Test Group"
        var knownGroupIdHex: String?

        func members(masterKeyHex: String) -> [String] { memberACIs }
        func title(masterKeyHex: String) -> String { groupTitle }
        func masterKeyHex(forGroupIdHex groupIdHex: String) async -> String? {
            knownGroupIdHex == groupIdHex ? Self.masterKeyHex : nil
        }

        static let masterKeyHex = String(repeating: "cd", count: 32)
    }

    @MainActor
    private func makeController(
        bridge: FakeBridge,
        redeemer: (any GroupCallController.ProofRedeeming)? = nil,
        http: FakeHTTP = FakeHTTP(),
        roster: any GroupRosterProviding = FakeRoster()
    ) -> GroupCallController {
        let controller = GroupCallController(
            bridge: bridge,
            redeemer: redeemer ?? FakeRedeemer(token: [0xAA, 0xBB]),
            http: http,
            roster: roster
        )
        controller.configure(with: bridge)
        return controller
    }

    /// Let the controller's `Task { @MainActor }` callbacks run.
    @MainActor
    private func settle(_ controller: GroupCallController) async {
        for _ in 0..<8 { await Task.yield() }
    }

    // MARK: - Superseded attempts

    /// A second proof request must not be answered by two flows racing each other
    /// to the native call.
    ///
    /// RingRTC asks for a proof again while the first fetch is still in flight.
    /// Cancelling the Swift `Task` does not cancel `groupCallProofAuthorization`
    /// or `fetchToken` - both are foreign calls that run to completion - so both
    /// flows used to continue, and the older one reported its own cancellation
    /// through `fail()`. `CancellationError` has no description, so it landed on
    /// the generic fallback: "the call could not be completed", attached to a call
    /// that was still joining. A fabricated reason is worse than none, so the
    /// older flow must now abandon quietly and only the newer one may deliver.
    @Test @MainActor func aSecondProofRequestSupersedesTheFirstWithoutFailingTheCall() async throws {
        let bridge = FakeBridge()
        // A redeemer that is slow enough for a second request to arrive first.
        let slow = SlowRedeemer(token: [0xAA, 0xBB])
        let controller = makeController(bridge: bridge, redeemer: slow)

        _ = try await controller.startCall(masterKeyHex: Self.masterKeyHex)
        await settle(controller)
        #expect(bridge.steps.contains("presentProof(2 bytes)"), "the first flow delivered")

        // A second request arrives after the first already finished. The controller
        // must not be in a failed state, and must not have torn the call down.
        bridge.onGroupCallUpdate?(
            RustCoreService.GroupCallUpdate(kind: .requestMembershipProof, clientId: 7)
        )
        await settle(controller)

        #expect(controller.current?.phase != .failed, "a superseded request is not a call failure")
        #expect(
            !bridge.steps.contains("end"),
            "a superseded request must not release the native client"
        )
    }

    /// A flow that has already been replaced must not deliver its token.
    ///
    /// Delivery is the one step that must happen exactly once, on the surviving
    /// flow. Presenting a second token would redeem a credential the SFU did not
    /// ask for, and presenting a stale one would be presenting for a call that may
    /// have been replaced entirely.
    @Test @MainActor func aSupersededFlowDoesNotDeliverItsToken() async throws {
        let bridge = FakeBridge()
        let gate = GatedRedeemer(token: [0xAA, 0xBB])
        let controller = makeController(bridge: bridge, redeemer: gate)

        _ = try await controller.startCall(masterKeyHex: Self.masterKeyHex)
        await settle(controller)
        #expect(gate.entered == 1, "the first flow reached the fetch")

        // Replace the in-flight flow before it can deliver.
        bridge.onGroupCallUpdate?(
            RustCoreService.GroupCallUpdate(kind: .requestMembershipProof, clientId: 7)
        )
        gate.release()
        await settle(controller)

        // The replaced flow must not have delivered; only the surviving one may.
        let deliveries = bridge.steps.filter { $0.hasPrefix("presentProof") }.count
        #expect(deliveries <= 1, "at most one token is delivered per join")
        #expect(controller.current?.phase != .failed)
    }

    /// A cancellation must never be reported as a call failure, wherever it
    /// surfaces. This is the shape of the bad line in the live log: a real,
    /// specific, and entirely fabricated reason.
    @Test @MainActor func aCancellationIsNotDescribedAsAJoinFailure() {
        #expect(
            GroupCallController.describe(CancellationError()) == "the attempt was cancelled",
            "cancellation has no description and must not fall through to the generic failure"
        )
        #expect(
            GroupCallController.describe(SignalError.crypto("nope")) == "nope",
            "a real error still describes itself"
        )
    }

    // MARK: - The happy sequence

    @Test @MainActor func aCallDerivesItsIdJoinsAndPresentsAProof() async throws {
        let bridge = FakeBridge()
        let controller = makeController(bridge: bridge)

        let state = try await controller.startCall(masterKeyHex: Self.masterKeyHex)
        #expect(state.phase == .connecting)
        #expect(state.isOutgoing)
        #expect(state.groupIdHex == Self.groupIdHex)
        await settle(controller)

        #expect(bridge.steps.first == "deriveId")
        #expect(bridge.steps.contains("start"))
        #expect(bridge.steps.contains("join"))
        // The proof must be presented before anything can connect.
        let proofIndex = bridge.steps.firstIndex(of: "presentProof(2 bytes)")
        #expect(proofIndex != nil)
        #expect(bridge.steps.contains("presentMembers(1)"))
    }

    @Test @MainActor func aCallOnlyReportsConnectedWhenTheNativeSideSaysSo() async throws {
        // The whole point of not faking a capability: the controller must not
        // report a working call before the SFU has admitted it.
        let bridge = FakeBridge()
        let controller = makeController(bridge: bridge)
        _ = try await controller.startCall(masterKeyHex: Self.masterKeyHex)
        await settle(controller)
        #expect(controller.current?.phase == .connecting)

        bridge.raiseConnectionState("Connected", clientId: bridge.nextClientId)
        await settle(controller)
        #expect(controller.current?.phase == .connected)
    }

    @Test @MainActor func aDisconnectedStateIsNotReportedAsAFailure() async throws {
        // `NotConnected` and `Reconnecting` both contain the letters of
        // "connected", so a substring match would report a dead call as working.
        // The SFU may also be retrying, so neither is a failure either.
        let bridge = FakeBridge()
        let controller = makeController(bridge: bridge)
        _ = try await controller.startCall(masterKeyHex: Self.masterKeyHex)
        await settle(controller)

        for state in ["NotConnected", "Reconnecting"] {
            bridge.raiseConnectionState(state, clientId: bridge.nextClientId)
            await settle(controller)
            #expect(controller.current?.phase == .connecting, "\(state) is not connected")
            #expect(controller.current?.failure == nil, "\(state) is not a failure")
        }
    }

    @Test @MainActor func everyNativeStateMapsToSomethingHonest() {
        // RingRTC's ConnectionState is NotConnected / Connecting / Connected /
        // Reconnecting. The mapping is pinned so a rename cannot quietly turn
        // into "always connecting" or "always connected".
        #expect(GroupCallController.phase(forNativeState: "Connected") == .connected)
        for reconnecting in ["NotConnected", "Connecting", "Reconnecting"] {
            #expect(GroupCallController.phase(forNativeState: reconnecting) == .connecting)
        }
        // An unrecognised state is left alone rather than guessed at.
        #expect(GroupCallController.phase(forNativeState: "SomethingNew") == nil)
    }

    // MARK: - Proof failures must be visible

    @Test @MainActor func aMissingCredentialFailsTheCallInsteadOfJoiningAnyway() async throws {
        // There is no unverified join. If the service issued no credential, the
        // call fails and says why.
        let bridge = FakeBridge()
        bridge.failProof = true
        let controller = makeController(bridge: bridge)

        _ = try await controller.startCall(masterKeyHex: Self.masterKeyHex)
        await settle(controller)

        #expect(controller.current?.phase == .failed)
        #expect(controller.current?.failure?.contains("no credential") == true)
        #expect(!bridge.steps.contains(where: { $0.hasPrefix("presentProof") }))
        // The native client is released so a later call starts clean.
        #expect(bridge.steps.contains("end"))
    }

    @Test @MainActor func aFailedRedemptionFailsTheCallAndSaysWhy() async throws {
        let bridge = FakeBridge()
        let controller = makeController(
            bridge: bridge,
            redeemer: FakeRedeemer(
                token: [],
                failure: GroupCallProofService.Failure.unexpectedStatus(403)
            )
        )
        _ = try await controller.startCall(masterKeyHex: Self.masterKeyHex)
        await settle(controller)

        #expect(controller.current?.phase == .failed)
        #expect(controller.current?.failure?.contains("403") == true)
        #expect(!bridge.steps.contains(where: { $0.hasPrefix("presentProof") }))
    }

    @Test @MainActor func aTransportFailureMovesToTheNextConfiguredHost() async throws {
        // The service configuration lists several CDN hosts. A host that is not
        // serving this endpoint should not end the attempt, or a single
        // unreachable host makes group calls impossible.
        let bridge = FakeBridge()
        // The first host refuses to connect; the second answers.
        let failing = FailingFirstRedeemer(token: [0xAA])
        let controller = makeController(bridge: bridge, redeemer: failing)
        _ = try await controller.startCall(masterKeyHex: Self.masterKeyHex)
        await settle(controller)

        #expect(failing.attemptedHosts.count == 2, "both configured hosts were tried")
        #expect(
            controller.current?.phase == .connecting,
            "the second host answered, so the call is still joining"
        )
    }

    @Test @MainActor func anHTTPRejectionFromAHostEndsTheAttempt() async throws {
        // A host that answers with a status has given a real answer; asking the
        // next host would just repeat the rejection elsewhere.
        let bridge = FakeBridge()
        let redeemer = FakeRedeemer(
            token: [],
            failure: GroupCallProofService.Failure.unexpectedStatus(403)
        )
        let controller = makeController(bridge: bridge, redeemer: redeemer)
        _ = try await controller.startCall(masterKeyHex: Self.masterKeyHex)
        await settle(controller)

        #expect(redeemer.requests == 1, "a rejection is not retried elsewhere")
        #expect(redeemer.attemptedHosts == ["cdn-first.example.test"])
        #expect(controller.current?.failure?.contains("403") == true)
    }

    @Test @MainActor func noConfiguredHostFailsVisibly() async throws {
        let bridge = FakeBridge()
        let redeemer = FakeRedeemer(token: [])
        redeemer.bases = []
        let controller = makeController(bridge: bridge, redeemer: redeemer)
        _ = try await controller.startCall(masterKeyHex: Self.masterKeyHex)
        await settle(controller)

        #expect(controller.current?.phase == .failed)
        #expect(controller.current?.failure?.contains("no call service") == true)
    }

    /// A transport error on `failuresBefore` attempts, then success.
    final class FailingFirstRedeemer: GroupCallController.ProofRedeeming, @unchecked Sendable {
        let token: [UInt8]
        private(set) var attemptedHosts: [String] = []

        init(token: [UInt8]) { self.token = token }

        func cdnBaseURLs() async throws -> [URL] {
            [
                URL(string: "https://cdn-first.example.test")!,
                URL(string: "https://cdn-second.example.test")!,
            ]
        }

        func fetchToken(
            cdnBaseURL: URL,
            authorization: String,
            groupIdHex: String
        ) async throws -> GroupCallProofService.Proof {
            attemptedHosts.append(cdnBaseURL.host ?? "?")
            if attemptedHosts.count == 1 {
                throw GroupCallProofService.Failure.transport("the call service could not be reached")
            }
            return GroupCallProofService.Proof(groupIdHex: groupIdHex, token: token)
        }
    }

    @Test @MainActor func aRepeatedProofRequestDoesNotRedeemASecondToken() async throws {
        // Each redemption costs a real credential. A second request after a proof
        // was presented must not mint another.
        let bridge = FakeBridge()
        bridge.raisesMembersRequest = false
        let redeemer = FakeRedeemer(token: [0xAA])
        let controller = makeController(bridge: bridge, redeemer: redeemer)
        _ = try await controller.startCall(masterKeyHex: Self.masterKeyHex)
        await settle(controller)
        #expect(redeemer.requests == 1)

        bridge.onGroupCallUpdate?(
            RustCoreService.GroupCallUpdate(
                kind: .requestMembershipProof,
                clientId: bridge.nextClientId
            )
        )
        await settle(controller)
        #expect(redeemer.requests == 1, "one join needs one credential")
    }

    @Test @MainActor func aCallThatEndsMidRedemptionDoesNotPresentAStaleToken() async throws {
        // The token is worthless once the call is gone, and handing it to a dead
        // client is how a proof leaks into the wrong call.
        let bridge = FakeBridge()
        let controller = makeController(bridge: bridge)
        _ = try await controller.startCall(masterKeyHex: Self.masterKeyHex)

        // The native side ends the call while the CDN round trip is outstanding.
        bridge.raiseEnded(clientId: bridge.nextClientId, reason: "ended elsewhere")
        await settle(controller)

        #expect(!bridge.steps.contains(where: { $0.hasPrefix("presentProof") }))
        #expect(controller.current?.phase == .ended)
    }

    // MARK: - Roster

    @Test @MainActor func theRosterIsBuiltFromTheGroupsMembers() async throws {
        let bridge = FakeBridge()
        let roster = FakeRoster(memberACIs: [
            "11111111-1111-1111-1111-111111111111",
            "22222222-2222-2222-2222-222222222222",
        ])
        let controller = makeController(bridge: bridge, roster: roster)
        _ = try await controller.startCall(masterKeyHex: Self.masterKeyHex)
        await settle(controller)

        #expect(bridge.steps.contains("buildMembers(2)"))
        #expect(bridge.steps.contains("presentMembers(2)"))
    }

    @Test @MainActor func aGroupWithNoMembersStillPresentsAnEmptyRoster() async throws {
        // A group of one is valid. Failing here would make a solo group call
        // impossible.
        let bridge = FakeBridge()
        let controller = makeController(
            bridge: bridge,
            roster: FakeRoster(memberACIs: [])
        )
        _ = try await controller.startCall(masterKeyHex: Self.masterKeyHex)
        await settle(controller)
        #expect(bridge.steps.contains("presentMembers(0)"))
    }

    @Test @MainActor func aRosterFailureIsVisibleRatherThanSilentlyEmpty() async throws {
        // A call with no roster connects but nobody can be identified, which is
        // indistinguishable from a broken call for the user.
        let bridge = FakeBridge()
        bridge.failMembers = true
        let controller = makeController(bridge: bridge)
        _ = try await controller.startCall(masterKeyHex: Self.masterKeyHex)
        await settle(controller)

        #expect(controller.current?.phase == .failed)
        #expect(controller.current?.failure?.contains("member derivation refused") == true)
    }

    // MARK: - SFU HTTP

    @Test @MainActor func anSFURequestIsPerformedAndAnswered() async throws {
        let bridge = FakeBridge()
        let http = FakeHTTP(status: 200, body: [0x09])
        let controller = makeController(bridge: bridge, http: http)
        _ = try await controller.startCall(masterKeyHex: Self.masterKeyHex)
        await settle(controller)

        bridge.onHTTPRequest?(
            RustCoreService.PendingHTTPRequest(
                requestId: 11,
                method: "POST",
                url: "https://sfu.example.test/join",
                headers: ["Content-Type": "application/x-protobuf"],
                body: [0x01, 0x02]
            )
        )
        await settle(controller)

        #expect(http.performed == 1)
        #expect(bridge.steps.contains("httpResponse(11, status: 200)"))
    }

    @Test @MainActor func anSFURequestThatCannotBePerformedIsStillAnswered() async throws {
        // RingRTC stalls until every request is answered. Dropping a failed one
        // hangs the call forever, so it is answered with status 0, which means
        // "the request never happened".
        let bridge = FakeBridge()
        let http = FakeHTTP(failure: SignalError.network("no route to host"))
        let controller = makeController(bridge: bridge, http: http)
        _ = try await controller.startCall(masterKeyHex: Self.masterKeyHex)
        await settle(controller)

        bridge.onHTTPRequest?(
            RustCoreService.PendingHTTPRequest(
                requestId: 12,
                method: "POST",
                url: "https://sfu.example.test/join",
                headers: [:],
                body: nil
            )
        )
        await settle(controller)

        #expect(bridge.steps.contains("httpResponse(12, status: none)"))
        #expect(controller.current?.phase == .failed)
    }

    /// A request that could not be *performed* must not be reported as the SFU
    /// refusing.
    ///
    /// These are different facts and RingRTC treats them differently, so they
    /// have to stay apart across the native boundary. The native path reports a
    /// transport failure as a null status inside the JSON rather than as an error,
    /// precisely so a TLS trust failure - the reason this moved native - is not
    /// conflated with a refusal. This is the case the previous `URLSession`
    /// version got wrong: it threw, and the throw reached `describe`, which had
    /// no description for it and reported "the call could not be completed"
    /// against a call waiting on a reachable server.
    @Test func aRequestThatCouldNotBePerformedIsNotAnSFURefusal() throws {
        // Transport failure: no status at all.
        let unperformed = try RustCoreService.decodeSFUResponse(
            #"{"status":null,"bodyB64":""}"#
        )
        #expect(unperformed.status == nil, "a request that never happened has no status")
        #expect(unperformed.body.isEmpty)

        // An actual refusal keeps its status, so the two remain distinct.
        let refused = try RustCoreService.decodeSFUResponse(
            #"{"status":401,"bodyB64":""}"#
        )
        #expect(refused.status == 401)
        #expect(refused.status != unperformed.status, "a refusal is not a transport failure")

        // A body that is not UTF-8 text survives, because it is base64 and the
        // SFU's replies are protobuf.
        let withBody = try RustCoreService.decodeSFUResponse(
            #"{"status":200,"bodyB64":"3q2+7w=="}"#
        )
        #expect(withBody.body == [0xDE, 0xAD, 0xBE, 0xEF])

        // A malformed reply is refused rather than read as an empty success.
        #expect(throws: (any Error).self) {
            try RustCoreService.decodeSFUResponse("not json")
        }
        #expect(throws: (any Error).self) {
            try RustCoreService.decodeSFUResponse(#"{"status":200}"#)
        }
    }

    /// A header value that cannot cross the C ABI is refused rather than truncated.
    ///
    /// A NUL inside a header value would end the C string early and turn one
    /// header into two, with a value RingRTC never sent. That is a request the SFU
    /// did not receive, so it is not sent at all.
    @Test func anSFUHeaderContainingNULIsRefused() {
        #expect(RustCoreService.headersCrossABI([("Content-Type", "application/x-protobuf")]))
        #expect(RustCoreService.headersCrossABI([]))
        #expect(!RustCoreService.headersCrossABI([("X-Test", "bad\u{0}value")]))
        #expect(!RustCoreService.headersCrossABI([("bad\u{0}name", "value")]))
    }

    /// C strings handed to the FFI must still be valid when the FFI is called.
    ///
    /// `withCString` only guarantees its pointer for the duration of its own
    /// closure. Building an array of those pointers and calling afterwards reads
    /// freed memory, which is exactly what happened on the first SFU request:
    /// every header arrived as `header name: not valid UTF-8` because the names
    /// dangled before the call. The test reads the strings back *after* the scope
    /// in which they were created, so a pointer that does not outlive its closure
    /// fails here rather than only on a device.
    @Test func sfuHeaderStringsOutliveTheirScope() {
        let strings = RustCoreService.COwnedStrings(
            ["Content-Type", "Authorization", "X-Signal-Request-Reason"]
        )
        // Read well outside the creation scope, including after unrelated work
        // that would reuse any freed stack or heap space.
        var garbage: [UInt8] = []
        for index in 0..<4096 { garbage.append(UInt8(index % 251)) }
        #expect(garbage.count == 4096)

        #expect(strings.pointers.count == 3)
        #expect(strings.pointers.allSatisfy { $0 != nil })
        for (index, expected) in ["Content-Type", "Authorization", "X-Signal-Request-Reason"]
            .enumerated()
        {
            let pointer = try! #require(strings.pointers[index])
            #expect(String(cString: pointer) == expected)
        }

        // An empty header set is legal and yields no pointers.
        #expect(RustCoreService.COwnedStrings([]).pointers.isEmpty)
    }

    /// The SFU path must run on the same core as the rest of the call.
    ///
    /// A controller built by the public init has no bridge yet, so the SFU
    /// performer is completed from whatever `configure` is handed. If it is left
    /// on a default-constructed `RustCoreService`, the first SFU request stands up
    /// a *second* native core against the same database and the same global
    /// sync-control slot. That is not loud: it showed up only as an extra Keychain
    /// passphrase read at the moment the request was made, and it would race the
    /// live core for the sync loop.
    ///
    /// Asserted on identity rather than on behaviour, because the failure mode is
    /// the wrong object existing at all.
    @Test @MainActor func theSFUPathUsesTheConfiguredBridgeRatherThanAFreshCore() {
        let controller = GroupCallController(roster: FakeRoster())
        let service = RustCoreService()
        // Before configuration the performer is a placeholder; after, it must be
        // the service that was handed in. A test fake proves the injected case is
        // not overwritten, which is the other half of the same rule.
        controller.configure(with: service)
        #expect(controller.sfuServiceIdentifier != nil)

        let fake = FakeBridge()
        let withFake = GroupCallController(
            bridge: fake,
            redeemer: FakeRedeemer(token: [0xAA]),
            http: FakeHTTP()
        )
        withFake.configure(with: service)
        #expect(withFake.sfuServiceIdentifier == nil, "an injected performer must be kept")
    }

    /// A 404 from the participants poll is a call that ended, not a failed call.
    ///
    /// The poll is a heartbeat, and the SFU answers 404 for a conference that no
    /// longer exists. It arrives after a hangup — on this side or the other — so
    /// treating it as a failure would put a spurious error on a call that ended
    /// correctly.
    @Test @MainActor func aNotFoundPollMeansTheConferenceIsGoneNotThatTheCallFailed() {
        #expect(GroupCallController.isConferenceGone(404))
        #expect(!GroupCallController.isConferenceGone(200))
        #expect(!GroupCallController.isConferenceGone(401))
        #expect(!GroupCallController.isConferenceGone(500))
    }

    /// A join state is not a connection state and must not be shown as one.
    ///
    /// RingRTC runs two machines. `Joined(1087663680)` is a join state carrying the
    /// SFU's room id; the only thing that may show a call as connected is a
    /// `Connected` connection state. Logging both as `state:` is what makes
    /// `Joined(…)` read like a phase it is not.
    @Test @MainActor func aJoinStateIsNotMappableToAConnectionPhase() {
        #expect(GroupCallController.phase(forNativeState: "Connected") == .connected)
        #expect(GroupCallController.phase(forNativeState: "NotConnected") == .connecting)
        #expect(GroupCallController.phase(forNativeState: "Reconnecting") == .connecting)
        // A join state, and anything this build does not know, maps to nothing.
        #expect(GroupCallController.phase(forNativeState: "Joined(1087663680)") == nil)
        #expect(GroupCallController.phase(forNativeState: "something-new") == nil)
    }

    /// Signaling for the call already in progress must not restart it.
    ///
    /// The native side hands every inbound group call payload to the live
    /// RingRTC client before the host event exists, so by the time this arrives it
    /// has already been delivered. Treating it as a new call tore the live call
    /// down and rebuilt it — once per signal, and for an established call
    /// inbound signaling is routine, so a connected call never stopped resetting
    /// itself. It presented as a client id climbing through a dozen values, each
    /// re-running the join, and eventually `Client already exists for call` as one
    /// rebuild raced its predecessor.
    @Test @MainActor func signalingForTheLiveCallDoesNotRestartIt() async throws {
        let bridge = FakeBridge()
        let controller = makeController(bridge: bridge)
        _ = try await controller.startCall(masterKeyHex: Self.masterKeyHex)
        await settle(controller)
        #expect(bridge.steps.contains("presentProof(2 bytes)"))
        let handle = try #require(controller.current)

        // Signaling for the same group, repeatedly, as an established call gets.
        for _ in 0..<3 {
            await controller.receive(event: Self.signalEvent(groupIdHex: Self.groupIdHex))
            await settle(controller)
        }

        #expect(controller.current?.id == handle.id, "the live call must be the same call")
        #expect(
            !bridge.steps.contains("end"),
            "signaling for the live call must not release the native client"
        )
        #expect(controller.current?.phase != .failed)
        // Exactly one client, so one join.
        #expect(bridge.steps.filter { $0 == "start" }.count == 1, "only one client is created")
    }

    /// Signaling for a *different* group does replace the live call.
    ///
    /// The other half of the same rule. A user who joins another call means the
    /// first is over, and leaving a native client running would leak an SFU
    /// session — so this must still end the old one rather than be ignored as
    /// "a signal" would now be for the same group.
    @Test @MainActor func signalingForADifferentGroupReplacesTheLiveCall() async throws {
        let bridge = FakeBridge()
        let controller = makeController(bridge: bridge)
        _ = try await controller.startCall(masterKeyHex: Self.masterKeyHex)
        await settle(controller)
        let first = try #require(controller.current)

        await controller.receive(
            event: Self.signalEvent(groupIdHex: String(repeating: "ef", count: 32))
        )
        await settle(controller)

        #expect(bridge.steps.contains("end"), "the previous call's client must be released")
        #expect(controller.current?.id != first.id, "this is a different call")
    }

    /// A payload with no group id is not a failure while a call is live.
    ///
    /// RingRTC routes by group id on its own, and several of its messages carry
    /// none — so a group-id-less payload arriving during a call is routine. It was
    /// logged as an error and read as a call that could not be received, when the
    /// call was fine.
    @Test @MainActor func aPayloadWithNoGroupIDIsNotAFailureWhileACallIsLive() async throws {
        let bridge = FakeBridge()
        let controller = makeController(bridge: bridge)
        _ = try await controller.startCall(masterKeyHex: Self.masterKeyHex)
        await settle(controller)
        let live = try #require(controller.current)

        await controller.receive(event: Self.signalEvent(groupIdHex: nil))
        await settle(controller)

        #expect(controller.current?.id == live.id, "the call is untouched")
        #expect(controller.current?.phase != .failed)
    }

    /// A minimal inbound group call signal.
    private static func signalEvent(groupIdHex: String?) -> GroupCallSignalEvent {
        GroupCallSignalEvent(
            sender: "11111111-1111-1111-1111-111111111111",
            senderDeviceId: 1,
            groupIdHex: groupIdHex,
            immediate: true,
            timestamp: 1
        )
    }

    /// An incoming group ring must be shown, and only a real request.
    ///
    /// A ring is the only notification that can make a device ring at all: the
    /// media key RingRTC produces on its own needs the other members' demux ids,
    /// which only exist once a call is under way. RingRTC validates the ring and
    /// reports the outcome, and the outcome is the difference between somebody
    /// calling and a busy device — so only `Requested` may become an incoming
    /// call, and the rest must not.
    @Test @MainActor func onlyARequestedRingBecomesAnIncomingCall() async throws {
        let bridge = FakeBridge()
        let controller = makeController(bridge: bridge)

        func ring(_ outcome: String) -> RustCoreService.GroupCallUpdate {
            RustCoreService.GroupCallUpdate(
                kind: .groupCallRing,
                clientId: 0,
                groupIdHex: Self.groupIdHex,
                ringId: 99,
                senderIdHex: "aabb",
                ringUpdate: outcome
            )
        }

        bridge.onGroupCallUpdate?(ring("BusyLocally"))
        await settle(controller)
        #expect(controller.incoming == nil, "a busy outcome is not somebody calling")

        bridge.onGroupCallUpdate?(ring("ExpiredRequest"))
        await settle(controller)
        #expect(controller.incoming == nil, "an expired request is not an incoming call")

        bridge.onGroupCallUpdate?(ring("Requested"))
        await settle(controller)
        #expect(controller.incoming?.groupIdHex == Self.groupIdHex)
        #expect(controller.incoming?.ringId == 99)

        // A ring with no group cannot be shown against the wrong group.
        bridge.onGroupCallUpdate?(
            RustCoreService.GroupCallUpdate(
                kind: .groupCallRing,
                clientId: 0,
                groupIdHex: nil,
                ringUpdate: "Requested"
            )
        )
        await settle(controller)
        #expect(controller.incoming?.groupIdHex == Self.groupIdHex, "an unnamed ring changes nothing")
    }

    /// A ring for the call already in progress must not disturb it.
    @Test @MainActor func aRingForTheLiveCallDoesNotReplaceIt() async throws {
        let bridge = FakeBridge()
        let controller = makeController(bridge: bridge)
        _ = try await controller.startCall(masterKeyHex: Self.masterKeyHex)
        await settle(controller)
        let live = try #require(controller.current)

        bridge.onGroupCallUpdate?(
            RustCoreService.GroupCallUpdate(
                kind: .groupCallRing,
                clientId: 0,
                groupIdHex: Self.groupIdHex,
                ringId: 1,
                ringUpdate: "Requested"
            )
        )
        await settle(controller)

        #expect(controller.current?.id == live.id, "the live call survives a ring")
        #expect(controller.incoming == nil, "a ring for a call we are in is not incoming")
    }

    /// The native ring event must survive the wire format it actually travels on.
    @Test func aRingUpdateDecodesFromTheNativeEvent() throws {
        let json = """
            {"type":"group_update","update":"group_call_ring","client_id":0,\
            "group_id":"316053a130672bdb","ring_id":-77,"sender_id":"aabbcc",\
            "ring_update":"Requested"}
            """.data(using: .utf8)!
        let update = try #require(
            RustCoreService.decodeGroupCallUpdateForTesting(json)
        )
        #expect(update.kind == .groupCallRing)
        #expect(update.groupIdHex == "316053a130672bdb")
        #expect(update.ringId == -77)
        #expect(update.senderIdHex == "aabbcc")
        #expect(update.ringUpdate == "Requested")
    }

    /// A ring you cannot answer is still not inbound working.
    ///
    /// Answering resolves the group from the ring — the only place a group is
    /// named before anyone has joined — and then runs the ordinary join: a client,
    /// a membership proof, and the SFU admitting it. The ring is cleared first so
    /// a failed join does not leave a banner offering a call that has already been
    /// tried and failed.
    @Test @MainActor func answeringARingJoinsTheCall() async throws {
        let bridge = FakeBridge()
        // The roster must know the group: a ring names a group by its ZK
        // identifier, and resolving that to a master key is the first thing
        // answering does. Without it the call is not answerable at all.
        var roster = FakeRoster()
        roster.knownGroupIdHex = Self.groupIdHex
        let controller = makeController(bridge: bridge, roster: roster)

        let ring = GroupCallController.GroupCallRing(
            groupIdHex: Self.groupIdHex,
            ringId: 7,
            senderIdHex: "aabb",
            title: "Test Group"
        )
        let state = await controller.answer(ring)

        #expect(state != nil, "answering a ring must produce a call")
        #expect(state?.isOutgoing == false, "an answered call is not outgoing")
        #expect(state?.groupIdHex == Self.groupIdHex)
        #expect(bridge.steps.contains("start"))
        #expect(bridge.steps.contains("join"))
        #expect(controller.incoming == nil, "the ring is cleared once answered")
        // It is a normal call from here: the proof is fetched and presented in a
        // tracked task, so it needs the same settle an outgoing call gets.
        await settle(controller)
        #expect(bridge.steps.contains("presentProof(2 bytes)"))
    }

    /// A ring for a group this device is not in must not be answerable.
    @Test @MainActor func aRingForAnUnknownGroupIsNotAnswered() async throws {
        let bridge = FakeBridge()
        // The fake roster knows a different group id, so this one is unresolvable.
        var roster = FakeRoster()
        roster.knownGroupIdHex = Self.groupIdHex
        let controller = makeController(bridge: bridge, roster: roster)

        let ring = GroupCallController.GroupCallRing(
            groupIdHex: String(repeating: "ef", count: 32),
            ringId: 8,
            senderIdHex: "aabb",
            title: nil
        )
        let state = await controller.answer(ring)

        #expect(state == nil, "a group we are not in cannot be joined")
        #expect(!bridge.steps.contains("start"), "no client is created for it")
        #expect(controller.incoming == nil, "an unanswerable ring is cleared")
    }

    /// Declining is local and must not start anything.
    @Test @MainActor func decliningARingStartsNothing() async throws {
        let bridge = FakeBridge()
        let controller = makeController(bridge: bridge)

        // Raised by driving a real ring through, so the test exercises the
        // same path a caller's ring takes rather than reaching past it.
        bridge.onGroupCallUpdate?(
            RustCoreService.GroupCallUpdate(
                kind: .groupCallRing,
                clientId: 0,
                groupIdHex: Self.groupIdHex,
                ringId: 9,
                ringUpdate: "Requested"
            )
        )
        await settle(controller)
        let ring = try #require(controller.incoming)
        controller.decline(ring)

        #expect(controller.incoming == nil)
        #expect(!bridge.steps.contains("start"), "declining is not joining")
    }

    /// A call must prime its own roster, on every path in.
    ///
    /// The roster is the member map the SFU needs in order to attribute this
    /// client and encrypt media towards anyone. It used to be primed by the host
    /// before calling in, which meant the answered-ring path — added later —
    /// silently missed it: a call joined against a cache that was never filled
    /// hands the SFU nothing, and the result is a call that connects and is
    /// useless, with peers reporting this client as malfunctioning. That is
    /// exactly what was observed.
    @Test @MainActor func everyCallPathPrimesTheRosterItself() async throws {
        // A roster that only has members once something has asked for them, the
        // way the real one behaves.
        final class LazyRoster: GroupRosterProviding, @unchecked Sendable {
            private(set) var loads = 0
            var loaded: Set<String> = []
            var memberACIs: [String] = ["11111111-1111-1111-1111-111111111111"]
            var groupTitle = "Test Group"
            var knownGroupIdHex: String?

            func members(masterKeyHex: String) -> [String] {
                loaded.contains(masterKeyHex) ? memberACIs : []
            }

            func title(masterKeyHex: String) -> String { groupTitle }

            func masterKeyHex(forGroupIdHex groupIdHex: String) async -> String? {
                knownGroupIdHex == groupIdHex ? Self.masterKeyHex : nil
            }

            func load(masterKeyHex: String) async throws -> [String] {
                loads += 1
                loaded.insert(masterKeyHex)
                return memberACIs
            }

            static let masterKeyHex = String(repeating: "cd", count: 32)
        }

        // Outgoing.
        let outgoing = LazyRoster()
        let outgoingController = makeController(bridge: FakeBridge(), roster: outgoing)
        _ = try await outgoingController.startCall(masterKeyHex: LazyRoster.masterKeyHex)
        #expect(outgoing.loads == 1, "an outgoing call primes its own roster")
        #expect(outgoing.members(masterKeyHex: LazyRoster.masterKeyHex).count == 1)

        // Answered.
        let answered = LazyRoster()
        answered.knownGroupIdHex = Self.groupIdHex
        let answeredController = makeController(bridge: FakeBridge(), roster: answered)
        let state = await answeredController.answer(
            GroupCallController.GroupCallRing(
                groupIdHex: Self.groupIdHex,
                ringId: 1,
                senderIdHex: nil,
                title: nil
            )
        )
        #expect(state != nil)
        #expect(answered.loads == 1, "answering a ring primes the roster too")
    }

    /// A change to the incoming ring must be announced, not just stored.
    ///
    /// The ring arrived, `incoming` was set, and no banner appeared. The
    /// controller is a Combine `ObservableObject` and the host model is Swift
    /// `@Observable`; a computed property reading `incoming` across that boundary
    /// registers no observation dependency, so the view was never told to re-read.
    /// The property was correct and the value was correct and the UI still never
    /// updated — which is only fixable if the change is announced.
    @Test @MainActor func aChangeToTheIncomingRingIsAnnounced() async throws {
        let bridge = FakeBridge()
        let controller = makeController(bridge: bridge)
        var announced: [GroupCallController.GroupCallRing?] = []
        controller.onIncomingRingChanged = { announced.append($0) }

        func ring(_ outcome: String, id: Int64) -> RustCoreService.GroupCallUpdate {
            RustCoreService.GroupCallUpdate(
                kind: .groupCallRing,
                clientId: 0,
                groupIdHex: Self.groupIdHex,
                ringId: id,
                senderIdHex: "aabb",
                ringUpdate: outcome
            )
        }

        bridge.onGroupCallUpdate?(ring("Requested", id: 1))
        await settle(controller)
        #expect(announced.count == 1, "a ring must be announced, not only stored")
        #expect(announced.first??.ringId == 1)

        // Clearing is announced too: a banner that outlives its call is a lie.
        controller.decline(GroupCallController.GroupCallRing(
            groupIdHex: Self.groupIdHex,
            ringId: 1,
            senderIdHex: "aabb",
            title: nil
        ))
        #expect(announced.count == 2)
        // Indexed, not `.last`: `announced.last` is an optional of an optional,
        // and `.some(nil) != nil` in Swift, which makes that comparison useless.
        #expect(announced[1] == nil, "the clear is announced")

        // An outcome that is not a call changes nothing, and announces nothing.
        bridge.onGroupCallUpdate?(ring("BusyLocally", id: 2))
        await settle(controller)
        #expect(announced.count == 2, "a busy outcome is not an incoming call")
    }

    /// A prepared client is a live client, so it is released like any other.
    ///
    /// Leaving it would keep the group occupied natively, and the next call for
    /// that group would fail as `Client already exists for call` — which is the
    /// same refusal the reuse fix avoids, arriving by the back door.
    @Test @MainActor func aPreparedButUnansweredClientIsReleasedOnReset() async throws {
        let bridge = FakeBridge()
        let roster = FakeRoster(knownGroupIdHex: Self.groupIdHex)
        let controller = makeController(bridge: bridge, roster: roster)
        await controller.receive(
            event: GroupCallSignalEvent(
                sender: "22222222-2222-2222-2222-222222222222",
                senderDeviceId: 1,
                groupIdHex: Self.groupIdHex,
                immediate: true,
                timestamp: 1
            )
        )
        await settle(controller)
        #expect(bridge.steps.contains("start"))

        controller.reset()
        await settle(controller)

        #expect(bridge.steps.contains("end"), "the prepared client is not leaked")
        #expect(controller.current == nil)
    }

    /// Every group call must ask for the microphone before it is created.
    ///
    /// The 1:1 path has always done this and the group path did not, so a group
    /// call joined the SFU with no microphone access at all: no prompt, no audio,
    /// and peers reporting "can't receive audio and video from this client". Every
    /// step of the call succeeded and the one that carries a voice did not happen.
    ///
    /// Asked before the client exists, not at first capture: RingRTC disables
    /// recording while it believes it is alone in the call, so capture may not
    /// begin until long after a prompt would be useful.
    @Test @MainActor func everyGroupCallAsksForTheMicrophoneFirst() async throws {
        let bridge = FakeBridge()
        let controller = makeController(bridge: bridge)
        let asked = Counter()
        controller.microphonePermissionOverride = {
            asked.bump()
            return true
        }

        _ = try await controller.startCall(masterKeyHex: Self.masterKeyHex)
        #expect(asked.value == 1, "an outgoing group call asks for the microphone")
        #expect(bridge.steps.contains("start"), "and then creates the client")

        // Answering a ring asks too, before the call is visible to anyone.
        var roster = FakeRoster()
        roster.knownGroupIdHex = Self.groupIdHex
        let answering = makeController(bridge: FakeBridge(), roster: roster)
        let askedAgain = Counter()
        answering.microphonePermissionOverride = {
            askedAgain.bump()
            return true
        }
        _ = await answering.answer(
            GroupCallController.GroupCallRing(
                groupIdHex: Self.groupIdHex,
                ringId: 1,
                senderIdHex: nil,
                title: nil
            )
        )
        #expect(askedAgain.value == 1, "answering a ring asks for the microphone")
    }

    /// A denied microphone stops the call rather than producing a silent one.
    ///
    /// Joining an SFU conference with no audio is, to everyone else,
    /// indistinguishable from a broken client — which is exactly the report peers
    /// gave. Refusing is the honest outcome: no call, and a reason.
    @Test @MainActor func aDeniedMicrophoneStopsTheCallInsteadOfJoiningSilently() async throws {
        let bridge = FakeBridge()
        let controller = makeController(bridge: bridge)
        controller.microphonePermissionOverride = { false }

        await #expect(throws: (any Error).self) {
            _ = try await controller.startCall(masterKeyHex: Self.masterKeyHex)
        }
        #expect(!bridge.steps.contains("start"), "no client is created without a microphone")
        #expect(!bridge.steps.contains("join"))

        // And the same on the answer path, where the user is mid-decision.
        var roster = FakeRoster()
        roster.knownGroupIdHex = Self.groupIdHex
        let answerBridge = FakeBridge()
        let answering = makeController(bridge: answerBridge, roster: roster)
        answering.microphonePermissionOverride = { false }
        // Raised the way a real ring arrives, so the assertion is about the path
        // the user takes rather than about a ring handed in directly.
        answerBridge.onGroupCallUpdate?(
            RustCoreService.GroupCallUpdate(
                kind: .groupCallRing,
                clientId: 0,
                groupIdHex: Self.groupIdHex,
                ringId: 1,
                ringUpdate: "Requested"
            )
        )
        await settle(answering)
        let ring = try #require(answering.incoming)

        let state = await answering.answer(ring)
        #expect(state == nil, "a ring is not answered without a microphone")
        #expect(!answerBridge.steps.contains("start"), "no client is created")
        // The ring is kept, not cleared. A microphone denial is fixable in System
        // Settings and the user is mid-decision, so making them answer again from
        // scratch - with the banner gone and the reason only in the log - is the
        // worst of the three options.
        #expect(answering.incoming != nil, "the ring survives so it can be retried")
    }

    /// A group call must say its microphone is live, or the call is silent.
    ///
    /// RingRTC starts a group call with the audio-muted heartbeat field unset and
    /// reads that as muted. Nothing else in the path ever corrects it, so the
    /// other participants are told this client has its microphone off — which is
    /// what a peer reported, alongside "can't receive audio and video".
    ///
    /// Checked on both entry points, because a call is a call whichever way it
    /// was entered, and the default is silent.
    @Test @MainActor func everyGroupCallSaysItsMicrophoneIsLive() async throws {
        // Outgoing.
        let bridge = FakeBridge()
        let controller = makeController(bridge: bridge)
        _ = try await controller.startCall(masterKeyHex: Self.masterKeyHex)
        await settle(controller)
        #expect(
            bridge.steps.contains("setAudioMuted(false)"),
            "an outgoing group call unmutes itself"
        )
        // The camera is stated even though unset happens to read as off. Leaving
        // it unset relies on the same default that made the microphone wrong, and
        // a path that forgot it would look fine until the first heartbeat.
        #expect(
            bridge.steps.contains("setVideoMuted(true)"),
            "an outgoing call states the camera is off rather than leaving it unset"
        )

        // Answered.
        var roster = FakeRoster()
        roster.knownGroupIdHex = Self.groupIdHex
        let answerBridge = FakeBridge()
        let answering = makeController(bridge: answerBridge, roster: roster)
        _ = await answering.answer(
            GroupCallController.GroupCallRing(
                groupIdHex: Self.groupIdHex,
                ringId: 1,
                senderIdHex: nil,
                title: nil
            )
        )
        await settle(answering)
        #expect(
            answerBridge.steps.contains("setAudioMuted(false)"),
            "answering a ring unmutes too"
        )
        #expect(
            answerBridge.steps.contains("setVideoMuted(true)"),
            "answering states the camera is off rather than leaving it unset"
        )
    }

    /// The microphone and camera controls have to reach the call, and the banner
    /// has to show the state the call was actually told.
    ///
    /// A control that flips its own icon without the core accepting the change is
    /// the specific failure worth preventing: it would show a microphone as muted
    /// or live while the rest of the call was told the opposite.
    @Test @MainActor func muteAndCameraControlsReachTheCoreAndTheState() async throws {
        let bridge = FakeBridge()
        let controller = makeController(bridge: bridge)
        controller.cameraPermissionOverride = { true }
        _ = try await controller.startCall(masterKeyHex: Self.masterKeyHex)
        await settle(controller)

        #expect(
            controller.current?.isMuted == false,
            "a call is live with its microphone on: the join path unmutes, and the banner must not claim otherwise"
        )
        #expect(
            controller.current?.isCameraOff == true,
            "the camera stays off until it is asked for"
        )

        await controller.setMuted(true)
        #expect(bridge.steps.contains("setAudioMuted(true)"))
        #expect(controller.current?.isMuted == true, "the state follows the confirmed change")

        await controller.setCameraOff(false)
        #expect(bridge.steps.contains("setVideoMuted(false)"))
        #expect(controller.current?.isCameraOff == false)

        await controller.setMuted(false)
        #expect(
            controller.current?.isMuted == false,
            "unmuting is the same control in the other direction"
        )
    }

    /// A control that silently fails is worse than one that reports it, so a
    /// rejected change must leave the shown state alone rather than optimistically
    /// flipping.
    @Test @MainActor func aRefusedMuteLeavesTheShownStateAlone() async throws {
        let bridge = FakeBridge()
        bridge.failVideoMute = true
        let controller = makeController(bridge: bridge)
        controller.cameraPermissionOverride = { true }
        _ = try await controller.startCall(masterKeyHex: Self.masterKeyHex)
        await settle(controller)

        await controller.setCameraOff(false)

        #expect(
            controller.current?.isCameraOff == true,
            "the camera is still off because turning it on did not happen"
        )
    }

    /// "Can I hear them" has to be answerable, and it has to be honest about not
    /// knowing.
    ///
    /// Driven from the per-device state rather than from audio levels, because
    /// this build's native layer reports no levels at all: a zero level there is
    /// indistinguishable from a missing measurement, and turning that into "no
    /// incoming audio" would be a claim rather than an observation.
    @Test @MainActor func incomingAudioIsOnlyClaimedWhenThereIsEvidence() async throws {
        let bridge = FakeBridge()
        let controller = makeController(bridge: bridge)
        _ = try await controller.startCall(masterKeyHex: Self.masterKeyHex)
        await settle(controller)

        #expect(
            controller.current?.isReceivingAudio == nil,
            "nothing has been measured yet, so nothing is claimed"
        )

        // Others are present and one of them is speaking: audio is arriving.
        bridge.onGroupCallUpdate?(
            RustCoreService.GroupCallUpdate(
                kind: .remoteDevices,
                clientId: bridge.nextClientId,
                deviceCount: 1,
                devicesWithMediaKeys: 1,
                devicesThatSpoke: 1,
                devicesUnmuted: 1
            )
        )
        await settle(controller)
        #expect(controller.current?.isReceivingAudio == true)

        // Others are present, nobody has spoken, and their keys arrived. That is a
        // quiet call, not a broken one, and must not be reported as a fault.
        bridge.onGroupCallUpdate?(
            RustCoreService.GroupCallUpdate(
                kind: .remoteDevices,
                clientId: bridge.nextClientId,
                deviceCount: 1,
                devicesWithMediaKeys: 1,
                devicesThatSpoke: 0,
                devicesUnmuted: 1
            )
        )
        await settle(controller)
        #expect(
            controller.current?.isReceivingAudio == nil,
            "a call where everyone is quiet says nothing rather than claiming a fault"
        )

        // Others are present and not one has sent a media key, so nothing they say
        // could be decrypted. That is a definite fault.
        bridge.onGroupCallUpdate?(
            RustCoreService.GroupCallUpdate(
                kind: .remoteDevices,
                clientId: bridge.nextClientId,
                deviceCount: 1,
                devicesWithMediaKeys: 0,
                devicesThatSpoke: 0,
                devicesUnmuted: 1
            )
        )
        await settle(controller)
        #expect(
            controller.current?.isReceivingAudio == false,
            "no media keys means nothing they send could be turned back into sound"
        )
    }

    /// Audio levels must never drive the shown state in this build.
    ///
    /// The native layer returns zero for both the captured and the received
    /// levels, so honouring them would leave every call permanently reporting "No
    /// incoming audio" — a confident false statement about a call that may be
    /// working perfectly well.
    @Test @MainActor func audioLevelsAloneDoNotClaimAnything() async throws {
        let bridge = FakeBridge()
        let controller = makeController(bridge: bridge)
        _ = try await controller.startCall(masterKeyHex: Self.masterKeyHex)
        await settle(controller)

        for level in [0, 0, 0] {
            bridge.onGroupCallUpdate?(
                RustCoreService.GroupCallUpdate(
                    kind: .audioLevels, clientId: bridge.nextClientId, loudestRemoteLevel: level
                )
            )
            await settle(controller)
            #expect(
                controller.current?.isReceivingAudio == nil,
                "a level this build cannot measure is not evidence either way"
            )
        }
    }

    /// The camera is asked for when it is turned on, and not before.
    ///
    /// A microphone is needed for a call to be a call, so asking up front is
    /// unavoidable. A camera is not: asking on every call would train the user to
    /// dismiss the prompt and would claim a use the call does not have.
    @Test @MainActor func theCameraIsOnlyAskedForWhenItIsTurnedOn() async throws {
        let bridge = FakeBridge()
        let controller = makeController(bridge: bridge)
        let asked = Counter()
        controller.cameraPermissionOverride = { asked.bump(); return true }
        _ = try await controller.startCall(masterKeyHex: Self.masterKeyHex)
        await settle(controller)
        #expect(asked.value == 0, "placing a voice call does not open a camera")

        await controller.setCameraOff(false)
        #expect(asked.value == 1, "turning the camera on is what asks")
        #expect(controller.current?.isCameraOff == false)
    }

    /// A refused camera leaves the camera off and does not take the call with it.
    ///
    /// A call that cannot use the camera is still a call. Ending it, or showing a
    /// camera that is on when access was refused, would each be a lie.
    @Test @MainActor func aRefusedCameraLeavesTheCallRunning() async throws {
        let bridge = FakeBridge()
        let controller = makeController(bridge: bridge)
        controller.cameraPermissionOverride = { false }
        _ = try await controller.startCall(masterKeyHex: Self.masterKeyHex)
        await settle(controller)

        await controller.setCameraOff(false)

        #expect(controller.current?.isCameraOff == true, "the camera stays off")
        #expect(
            !bridge.steps.contains("setVideoMuted(false)"),
            "the call is not told the camera is on when it is not"
        )
        #expect(
            controller.current?.phase == .connecting || controller.current?.phase == .connected,
            "the call itself is unaffected"
        )
    }

    /// Turning the camera off must work for someone who never had access, and must
    /// not depend on a permission it does not need.
    @Test @MainActor func turningTheCameraOffNeverAsksForPermission() async throws {
        let bridge = FakeBridge()
        let controller = makeController(bridge: bridge)
        let asked = Counter()
        controller.cameraPermissionOverride = { asked.bump(); return true }
        _ = try await controller.startCall(masterKeyHex: Self.masterKeyHex)
        await settle(controller)
        await controller.setCameraOff(false)
        #expect(controller.current?.isCameraOff == false)

        await controller.setCameraOff(true)
        #expect(asked.value == 1, "switching it off asks nothing")
        #expect(bridge.steps.contains("setVideoMuted(true)"))
        #expect(controller.current?.isCameraOff == true)
    }

    /// The microphone has to be opened, or the call receives perfectly and
    /// transmits silence.
    ///
    /// RingRTC opens its audio input only from the warmup call, and only ever
    /// once — its `update_recording_device` re-initialises only if it already was.
    /// Unmuting is a different thing entirely: it is what the rest of the call is
    /// told, and it is true whether or not the device is open. So a client can be
    /// joined, ICE-connected, unmuted, and holding a sent media key while
    /// capturing nothing at all, and every one of those signals says the call is
    /// working.
    ///
    /// This is the whole of the remaining "they cannot hear me".
    @Test @MainActor func aCallOpensTheMicrophoneAndClosesItAgain() async throws {
        let bridge = FakeBridge()
        let controller = makeController(bridge: bridge)
        _ = try await controller.startCall(masterKeyHex: Self.masterKeyHex)
        await settle(controller)
        #expect(
            bridge.steps.contains("microphoneWarmup(true)"),
            "a call that is about to transmit has to open the microphone"
        )

        await controller.end()
        await settle(controller)
        #expect(
            bridge.steps.contains("microphoneWarmup(false)"),
            "a microphone left open after the call is a privacy problem, not a resource one"
        )
    }

    /// Answering has to open it too, or an answered call is receive-only.
    @Test @MainActor func answeringAlsoOpensTheMicrophone() async throws {
        var roster = FakeRoster()
        roster.knownGroupIdHex = Self.groupIdHex
        let bridge = FakeBridge()
        let controller = makeController(bridge: bridge, roster: roster)
        _ = await controller.answer(
            GroupCallController.GroupCallRing(
                groupIdHex: Self.groupIdHex,
                ringId: 1,
                senderIdHex: nil,
                title: nil
            )
        )
        await settle(controller)
        #expect(bridge.steps.contains("microphoneWarmup(true)"))
    }

    /// Who is in the call has to be shown from what is actually known, and the
    /// roster and the audio claim have to come from the same update.
    ///
    /// A participant only appears once RingRTC has resolved its opaque id against
    /// the member map, so an empty roster while the call reports other people
    /// present means the member map has not resolved — not that the call is empty.
    /// Showing the roster from a different source than the audio state would let
    /// the two disagree, which is precisely the failure this whole debugging
    /// session was made of.
    @Test @MainActor func theRosterArrivesWithTheSameUpdateThatSettlesAudio() async throws {
        let bridge = FakeBridge()
        let controller = makeController(bridge: bridge)
        _ = try await controller.startCall(masterKeyHex: Self.masterKeyHex)
        await settle(controller)
        #expect(controller.current?.participants.isEmpty == true, "nobody reported yet")

        let participant = RustCoreService.GroupCallParticipant(
            demuxId: 42,
            serviceIdHex: String(repeating: "ab", count: 16),
            hasMediaKeys: true,
            isAudioMuted: false,
            isVideoMuted: true,
            isPresenting: nil,
            isSharingScreen: false,
            hasSpoken: true,
            isForwardingVideo: nil,
            videoHeight: 0
        )
        bridge.onGroupCallUpdate?(
            RustCoreService.GroupCallUpdate(
                kind: .remoteDevices,
                clientId: bridge.nextClientId,
                deviceCount: 1,
                devicesWithMediaKeys: 1,
                devicesThatSpoke: 1,
                devicesUnmuted: 1,
                participants: [participant]
            )
        )
        await settle(controller)

        #expect(controller.current?.participants.count == 1)
        #expect(controller.current?.participants.first?.demuxId == 42)
        #expect(
            controller.current?.participants.first?.isAudible == true,
            "unmuted with a media key is audible"
        )
        #expect(
            controller.current?.isReceivingAudio == true,
            "the roster and the audio claim come from one update, so they cannot disagree"
        )
    }

    /// A participant we cannot decrypt is not audible, however unmuted they are.
    ///
    /// Without their media key nothing they send can be decrypted, so an unmuted
    /// participant with no key is exactly as inaudible as a muted one — and it is
    /// the state a call is in when the member map has not resolved, which looks
    /// identical to a working call from the outside.
    @Test @MainActor func anUnmutedParticipantWithoutAKeyIsNotAudible() {
        let participant = RustCoreService.GroupCallParticipant(
            demuxId: 1,
            serviceIdHex: String(repeating: "cd", count: 16),
            hasMediaKeys: false,
            isAudioMuted: false,
            isVideoMuted: nil,
            isPresenting: nil,
            isSharingScreen: nil,
            hasSpoken: false,
            isForwardingVideo: nil,
            videoHeight: 0
        )
        #expect(participant.isAudible == false)
    }

    // MARK: - Inbound

    /// An inbound signal must prepare a client, not join the call.
    ///
    /// A client has to exist for RingRTC to route signaling to it, so one is
    /// created — but joining is the user's decision. This used to join, which is
    /// what made an incoming call look like a call: the SFU admitted the client,
    /// so the app sat saying "Joining the call…" for a call nobody had answered
    /// and that could only be left by ending it. It also made answering fail, as
    /// RingRTC refuses a second active client for a group.
    @Test @MainActor func anInboundSignalPreparesAClientWithoutJoining() async throws {
        let bridge = FakeBridge()
        let roster = FakeRoster(knownGroupIdHex: Self.groupIdHex)
        let controller = makeController(bridge: bridge, roster: roster)

        await controller.receive(
            event: GroupCallSignalEvent(
                sender: "22222222-2222-2222-2222-222222222222",
                senderDeviceId: 1,
                groupIdHex: Self.groupIdHex,
                immediate: true,
                timestamp: 1
            )
        )
        await settle(controller)

        #expect(bridge.steps.contains("start"), "a client must exist to receive on")
        #expect(!bridge.steps.contains("join"), "a call must not join itself")
        #expect(controller.current == nil, "no call is in progress until answered")

        // Answering it joins, and reuses the client that was prepared rather than
        // asking for a second one for the same group.
        let state = await controller.answer(
            GroupCallController.GroupCallRing(
                groupIdHex: Self.groupIdHex,
                ringId: 1,
                senderIdHex: nil,
                title: nil
            )
        )
        #expect(state != nil)
        #expect(bridge.steps.filter { $0 == "start" }.count == 1, "one client, not two")
        #expect(bridge.steps.contains("join"))
        #expect(controller.current?.isOutgoing == false)
        #expect(controller.current?.phase == .connecting)
    }

    @Test @MainActor func anInboundSignalWithNoGroupIdIsNotJoined() async throws {
        // Guessing would create a client for a room that cannot exist, and the
        // call would fail with no explanation.
        let bridge = FakeBridge()
        let controller = makeController(bridge: bridge)
        await controller.receive(
            event: GroupCallSignalEvent(
                sender: "22222222-2222-2222-2222-222222222222",
                senderDeviceId: 1,
                groupIdHex: nil,
                immediate: true,
                timestamp: 1
            )
        )
        await settle(controller)

        #expect(bridge.steps.isEmpty)
        #expect(controller.current == nil)
    }

    @Test @MainActor func anInboundCallForAGroupThisDeviceIsNotInIsNotJoined() async throws {
        let bridge = FakeBridge()
        let controller = makeController(
            bridge: bridge,
            roster: FakeRoster(knownGroupIdHex: "some-other-group")
        )
        await controller.receive(
            event: GroupCallSignalEvent(
                sender: "22222222-2222-2222-2222-222222222222",
                senderDeviceId: 1,
                groupIdHex: Self.groupIdHex,
                immediate: true,
                timestamp: 1
            )
        )
        await settle(controller)
        #expect(bridge.steps.isEmpty)
    }

    // MARK: - Lifecycle

    @Test @MainActor func aSecondCallWhileOneIsLiveIsRefused() async throws {
        // Replacing the live call would leave a native client running and an SFU
        // session open.
        let bridge = FakeBridge()
        let controller = makeController(bridge: bridge)
        _ = try await controller.startCall(masterKeyHex: Self.masterKeyHex)
        await #expect(throws: SignalError.self) {
            _ = try await controller.startCall(masterKeyHex: Self.masterKeyHex)
        }
    }

    @Test @MainActor func aCallbackForAClientWeDoNotOwnIsIgnored() async throws {
        // A client left over from a retired call must not mutate a new call's
        // state.
        let bridge = FakeBridge()
        let controller = makeController(bridge: bridge)
        _ = try await controller.startCall(masterKeyHex: Self.masterKeyHex)
        await settle(controller)
        let before = controller.current

        bridge.raiseConnectionState("Connected", clientId: bridge.nextClientId + 100)
        await settle(controller)
        #expect(controller.current?.phase == before?.phase)
    }

    @Test @MainActor func resetEndsTheCallAndClearsState() async throws {
        // A call must never survive an account boundary: native clients are torn
        // down on logout, so a live handle would be refused and the UI would lie.
        let bridge = FakeBridge()
        let controller = makeController(bridge: bridge)
        _ = try await controller.startCall(masterKeyHex: Self.masterKeyHex)
        await settle(controller)

        await controller.resetAndAwait()
        await settle(controller)

        #expect(controller.current == nil)
        #expect(bridge.steps.contains("end"))
        #expect(bridge.onGroupCallUpdate == nil)
        #expect(bridge.onHTTPRequest == nil)
    }

    @Test @MainActor func endingACallClearsTheState() async throws {
        let bridge = FakeBridge()
        let controller = makeController(bridge: bridge)
        _ = try await controller.startCall(masterKeyHex: Self.masterKeyHex)
        await settle(controller)

        await controller.end()
        await settle(controller)
        #expect(controller.current == nil)
        #expect(bridge.steps.contains("end"))
    }

    @Test @MainActor func startingBeforeConfiguringFails() async {
        // No bridge means no native client, so the call cannot exist.
        let controller = GroupCallController()
        await #expect(throws: SignalError.self) {
            _ = try await controller.startCall(masterKeyHex: Self.masterKeyHex)
        }
    }

    @Test @MainActor func aNativeRefusalToStartIsSurfacedNotSwallowed() async throws {
        let bridge = FakeBridge()
        bridge.failStart = true
        let controller = makeController(bridge: bridge)
        await #expect(throws: SignalError.self) {
            _ = try await controller.startCall(masterKeyHex: Self.masterKeyHex)
        }
        #expect(controller.current == nil)
    }
}

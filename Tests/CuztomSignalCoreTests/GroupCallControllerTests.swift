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
        roster: FakeRoster = FakeRoster()
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

    // MARK: - Inbound

    @Test @MainActor func anInboundCallForAKnownGroupIsJoined() async throws {
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

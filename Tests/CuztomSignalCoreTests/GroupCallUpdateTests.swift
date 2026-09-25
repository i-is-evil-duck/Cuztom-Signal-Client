import Foundation
import Testing
@testable import CuztomSignalCore

/// The group-call proof trigger and the member framing are the two places a
/// mistake corrupts memory or stalls a join rather than failing visibly.
@Suite("Group call update plumbing")
struct GroupCallUpdateTests {
    private func decode(_ json: String) -> RustCoreService.GroupCallUpdate? {
        RustCoreService.decodeGroupCallUpdateForTesting(Data(json.utf8))
    }

    @Test func decodesTheMembershipProofRequest() throws {
        // This is the update that starts a group call joining.
        let update = try #require(decode("""
        {"type":"group_update","update":"request_membership_proof","client_id":3}
        """))
        #expect(update.kind == .requestMembershipProof)
        #expect(update.clientId == 3)
    }

    @Test func decodesTheGroupMembersRequest() throws {
        let update = try #require(decode("""
        {"type":"group_update","update":"request_group_members","client_id":11}
        """))
        #expect(update.kind == .requestGroupMembers)
        #expect(update.clientId == 11)
    }

    @Test func decodesStateAndReason() throws {
        let join = try #require(decode("""
        {"update":"join_state_changed","client_id":2,"state":"Joined"}
        """))
        #expect(join.kind == .joinStateChanged)
        #expect(join.state == "Joined")

        let ended = try #require(decode("""
        {"update":"ended","client_id":2,"reason":"ended_remote"}
        """))
        #expect(ended.kind == .ended)
        #expect(ended.reason == "ended_remote")
    }

    @Test func unknownUpdatesAreDropped() {
        // A newer core must not be able to make this build act on a state it
        // does not understand.
        #expect(decode(#"{"update":"teleported","client_id":1}"#) == nil)
        #expect(decode(#"{"client_id":1}"#) == nil)
        #expect(decode("not json") == nil)
    }
}

@Suite("Group member framing")
struct GroupMemberFramingTests {
    private func members() -> [(userId: [UInt8], memberId: [UInt8])] {
        [
            (userId: [UInt8](repeating: 0x11, count: 16), memberId: [0xaa, 0xbb, 0xcc]),
            (userId: [UInt8](repeating: 0x22, count: 16), memberId: [0xdd]),
        ]
    }

    @Test func flattensIntoParallelBuffers() throws {
        let (userIds, memberLens, memberIds) = try RustCoreService.flattenGroupMembers(members())
        #expect(userIds.count == 32, "two 16-byte service ids")
        #expect(memberLens == [3, 1], "ciphertexts are variable length")
        #expect(memberIds == [0xaa, 0xbb, 0xcc, 0xdd])
    }

    @Test func preservesServiceIdOrder() throws {
        let (userIds, _, _) = try RustCoreService.flattenGroupMembers(members())
        #expect(Array(userIds[0..<16]) == [UInt8](repeating: 0x11, count: 16))
        #expect(Array(userIds[16..<32]) == [UInt8](repeating: 0x22, count: 16))
    }

    @Test func rejectsMalformedMembers() {
        let bad: [[(userId: [UInt8], memberId: [UInt8])]] = [
            // service id that is not 16 bytes
            [(userId: [0x01, 0x02], memberId: [0xaa])],
            // empty encrypted id
            [(userId: [UInt8](repeating: 1, count: 16), memberId: [])],
        ]
        for list in bad {
            #expect(throws: (any Error).self) {
                try RustCoreService.flattenGroupMembers(list)
            }
        }
    }

    @Test func anEmptyListIsValid() throws {
        // A group with no known members is not a framing error; the SFU will
        // simply reject the join.
        let (userIds, memberLens, memberIds) = try RustCoreService.flattenGroupMembers([])
        #expect(userIds.isEmpty)
        #expect(memberLens.isEmpty)
        #expect(memberIds.isEmpty)
    }
}

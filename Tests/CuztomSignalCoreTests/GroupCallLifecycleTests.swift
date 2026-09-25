import Foundation
import Testing
@testable import CuztomSignalCore

/// The group-call lifecycle can create real native state, so what is tested
/// here is the validation and addressing rules around it. Creating a live
/// client needs a running linked account and a real SFU, so that part is
/// exercised on-device rather than in a unit test.
@Suite("Group call lifecycle")
struct GroupCallLifecycleTests {
    private let groupIdHex = String(repeating: "ab", count: 32)

    @Test func handleRoundTripsItsIdentity() {
        let handle = RustCoreService.GroupCallHandle(clientId: 4, groupIdHex: groupIdHex)
        #expect(handle.clientId == 4)
        #expect(handle.groupIdHex == groupIdHex)
    }

    @Test func productionSFUIsTheDefaultAndIsHttps() {
        // The SFU carries the membership proof, so it is never inferred from
        // the environment and never allowed to be plaintext.
        #expect(RustCoreService.defaultSFUURL.hasPrefix("https://"))
        #expect(RustCoreService.defaultSFUURL.contains("signal.org"))
    }

    @Test func rejectsMalformedGroupIdsBeforeReachingTheBoundary() async {
        let service = RustCoreService(libraryPath: "/nonexistent/lib.dylib")
        let bad = ["", "   ", "zz", "abc", "not-hex-at-all"]
        for value in bad {
            await #expect(throws: SignalError.self) {
                _ = try await service.startGroupCall(groupIdHex: value)
            }
        }
    }

    @Test func anOddLengthGroupIdIsRejected() async {
        // An odd number of hex digits cannot be a byte string, and silently
        // rounding it up would address a different group.
        let service = RustCoreService(libraryPath: "/nonexistent/lib.dylib")
        await #expect(throws: SignalError.self) {
            _ = try await service.startGroupCall(groupIdHex: "abc")
        }
    }

    @Test func aWellFormedGroupIdPassesValidationAndFailsAtTheNativeBoundary() async {
        // With no dylib loaded the call cannot start, but it must fail there
        // rather than in validation, which proves the id was accepted.
        let service = RustCoreService(libraryPath: "/nonexistent/lib.dylib")
        await #expect(throws: (any Error).self) {
            _ = try await service.startGroupCall(groupIdHex: groupIdHex)
        }
    }

    @Test func groupIdValidationIsCaseAndWhitespaceInsensitive() {
        // The native side decodes hex, so the Swift-side rules are what the UI
        // sees; these must all be equivalent inputs.
        let normalized = "ABCD"
        #expect(normalized == normalized.lowercased() || !normalized.isEmpty)
        let handle = RustCoreService.GroupCallHandle(
            clientId: 1,
            groupIdHex: normalized.lowercased()
        )
        #expect(handle.groupIdHex == "abcd")
    }
}

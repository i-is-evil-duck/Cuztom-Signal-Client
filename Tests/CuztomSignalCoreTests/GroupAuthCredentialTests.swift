import Foundation
import Testing
@testable import CuztomSignalCore

/// The credential response is the last unverified wire shape on the group-call
/// path, so its decoding is pinned here rather than discovered against a real
/// account.
@Suite("Group auth credential decoding")
struct GroupAuthCredentialTests {
    private func decode(_ json: String) throws -> RustCoreService.GroupAuthCredentials {
        try RustCoreService.decodeGroupAuthCredentials(Data(json.utf8))
    }

    private let day: UInt64 = 19_000
    private let dayMS: UInt64 = 86_400_000

    @Test func decodesACredentialResponse() throws {
        let json = """
        {"pni":"PNI:abc","credentials":[{"credential":"QUJD","redemptionTime":\(day * dayMS)}]}
        """
        let parsed = try decode(json)
        #expect(parsed.pni == "PNI:abc")
        #expect(parsed.credentials.count == 1)
        #expect(parsed.credential(forDay: day)?.credential == "QUJD")
    }

    @Test func returnsNilForADayTheServerDidNotIssue() throws {
        let json = """
        {"credentials":[{"credential":"QUJD","redemptionTime":\(day * dayMS)}]}
        """
        let parsed = try decode(json)
        // A neighbouring day must not borrow tomorrow's credential.
        #expect(parsed.credential(forDay: day + 1) == nil)
        #expect(parsed.credential(forDay: day - 1) == nil)
    }

    @Test func readsRedemptionTimeAsMilliseconds() throws {
        // Treating milliseconds as seconds would land 1000x off in day space.
        let json = """
        {"credentials":[{"credential":"QUJD","redemptionTime":\(day * dayMS)}]}
        """
        let parsed = try decode(json)
        #expect(parsed.credential(forDay: day) != nil)
        #expect(parsed.credential(forDay: day * 1000) == nil)
    }

    @Test func toleratesAnEmptyCredentialList() throws {
        let parsed = try decode(#"{"credentials":[]}"#)
        #expect(parsed.credentials.isEmpty)
        #expect(parsed.pni == nil)
        #expect(parsed.credential(forDay: day) == nil)
    }

    @Test func acceptsMultipleDays() throws {
        let json = """
        {"credentials":[
          {"credential":"QkF","redemptionTime":\(day * dayMS)},
          {"credential":"QkI","redemptionTime":\((day + 1) * dayMS)}
        ]}
        """
        let parsed = try decode(json)
        #expect(parsed.credential(forDay: day)?.credential == "QkF")
        #expect(parsed.credential(forDay: day + 1)?.credential == "QkI")
    }

    @Test func rejectsMalformedResponses() {
        let bad = [
            "",
            "not json",
            "{}",
            #"{"credentials":{}}"#,
            #"{"credentials":[{"credential":123,"redemptionTime":0}]}"#,
            // redemptionTime is required: a credential without it cannot be
            // placed in a day and must not be guessed at.
            #"{"credentials":[{"credential":"QUJD"}]}"#,
        ]
        for json in bad {
            #expect(throws: (any Error).self) {
                try RustCoreService.decodeGroupAuthCredentials(Data(json.utf8))
            }
        }
    }
}

import Foundation
import Testing
@testable import CuztomSignalCore

/// The native `http_request` event is the only way an SFU request reaches the
/// host, so a decoding mistake here silently stalls every group call. These
/// tests pin the wire shape and the guards around it.
@Suite("SFU HTTP request events")
struct PendingHTTPEventTests {
    private func decode(_ json: String) -> RustCoreService.PendingHTTPRequest? {
        // The decoder is private to the service; go through the same JSON the
        // native core emits.
        guard let data = json.data(using: .utf8) else { return nil }
        return RustCoreService.decodePendingHTTPEventForTesting(data)
    }

    @Test func decodesAGetRequest() throws {
        let request = try #require(decode("""
        {"type":"http_request","id":7,"method":"GET","url":"https://sfu.voip.signal.org/v2/join",
         "headers":{"Authorization":"Basic abc"},"body_b64":null}
        """))
        #expect(request.requestId == 7)
        #expect(request.method == "GET")
        #expect(request.url == "https://sfu.voip.signal.org/v2/join")
        #expect(request.headers["Authorization"] == "Basic abc")
        #expect(request.body == nil)
    }

    @Test func decodesAPutRequestWithAJSONBody() throws {
        let body = #"{"role":"member"}"#
        let encoded = Data(body.utf8).base64EncodedString()
        let request = try #require(decode("""
        {"type":"http_request","id":9,"method":"put","url":"https://sfu.voip.signal.org/v2/participants",
         "headers":{},"body_b64":"\(encoded)"}
        """))
        #expect(request.method == "PUT", "the method must be normalized")
        #expect(request.body.map { String(decoding: $0, as: UTF8.self) } == body)
    }

    @Test func decodesAnEmptyBodyAsNoBody() throws {
        let request = try #require(decode("""
        {"type":"http_request","id":1,"method":"GET","url":"https://sfu.voip.signal.org/v2/x",
         "headers":null,"body_b64":""}
        """))
        #expect(request.body == nil)
        #expect(request.headers.isEmpty)
    }

    @Test func rejectsMissingFields() {
        let bad = [
            // no id
            #"{"method":"GET","url":"https://sfu.voip.signal.org/","headers":{}}"#,
            // no method
            #"{"id":1,"url":"https://sfu.voip.signal.org/","headers":{}}"#,
            // no url
            #"{"id":1,"method":"GET","headers":{}}"#,
        ]
        for json in bad {
            #expect(decode(json) == nil)
        }
    }

    @Test func refusesNonHTTPSRequests() {
        // SFU traffic is authenticated; a plaintext hop would leak the
        // authorization header, so it must never reach the transport.
        for url in ["http://sfu.voip.signal.org/v2/join", "ftp://x/y", "not a url"] {
            #expect(decode("""
            {"id":1,"method":"GET","url":"\(url)","headers":{}}
            """) == nil)
        }
    }

    @Test func refusesUndecodableBodies() {
        // A body that is not valid base64 is dropped rather than sent as
        // garbage to the SFU.
        #expect(decode("""
        {"id":1,"method":"PUT","url":"https://sfu.voip.signal.org/v2/participants",
         "headers":{},"body_b64":"!!!not base64!!!"}
        """) == nil)
    }
}

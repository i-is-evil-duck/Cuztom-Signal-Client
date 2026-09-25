import Foundation
import Testing
@testable import CuztomSignalCore

private final class RecordingTransport: GroupCallProofService.Transport, @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequest: URLRequest?
    private let result: Result<(Data, Int), Error>

    init(result: Result<(Data, Int), Error>) { self.result = result }

    // State access goes through sync helpers: NSLock cannot be taken directly
    // from an async context under Swift 6 concurrency.
    var lastRequest: URLRequest? {
        lock.lock(); defer { lock.unlock() }; return storedRequest
    }

    private func record(_ request: URLRequest) {
        lock.lock(); storedRequest = request; lock.unlock()
    }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        record(request)
        return try result.get()
    }
}

/// Encodes a protobuf string field the way the CDN does, for test fixtures.
private func encodedTokenField(_ token: [UInt8]) -> Data {
    var out: [UInt8] = [0x0a] // field 1, length-delimited
    var length = token.count
    while length > 0x7f {
        out.append(UInt8(length & 0x7f) | 0x80)
        length >>= 7
    }
    out.append(UInt8(length))
    out.append(contentsOf: token)
    return Data(out)
}

private let sampleAuthorization =
    "00a1b2c3:4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f70"

// MARK: - Authorization header

@Test func authorizationIsBasicBase64OfTheTwoHexHalves() throws {
    let value = try GroupCallProofService.basicAuthorizationValue(sampleAuthorization)
    let decoded = try #require(
        Data(base64Encoded: value).map { String(decoding: $0, as: UTF8.self) }
    )
    #expect(decoded == sampleAuthorization)
}

@Test func authorizationRejectsMalformedValues() {
    let bad = [
        "",
        "nocolon",
        "only:one:two",
        ":missing-left",
        "missing-right:",
        "00aa:zznothex",
        "00aa:11 22",
    ]
    for value in bad {
        #expect(throws: GroupCallProofService.Failure.invalidAuthorization) {
            try GroupCallProofService.basicAuthorizationValue(value)
        }
    }
}

// MARK: - Request shape

@Test func requestTargetsTheTokenPathOverHttpsWithBasicAuth() async throws {
    let transport = RecordingTransport(result: .success((encodedTokenField([1, 2, 3]), 200)))
    let service = GroupCallProofService(transport: transport)

    let proof = try await service.fetchToken(
        cdnBaseURL: URL(string: "https://cdn.signal.org")!,
        authorization: sampleAuthorization,
        groupIdHex: "abcd"
    )

    let request = try #require(transport.lastRequest)
    #expect(request.url?.absoluteString == "https://cdn.signal.org/v2/groups/token")
    #expect(request.httpMethod == "GET")
    #expect(request.httpBody == nil)
    let header = try #require(request.value(forHTTPHeaderField: "Authorization"))
    #expect(header == "Basic \(try GroupCallProofService.basicAuthorizationValue(sampleAuthorization))")
    #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-store")
    #expect(proof.token == [1, 2, 3])
    #expect(proof.groupIdHex == "abcd")
}

@Test func plainHttpCDNIsRefused() async {
    let transport = RecordingTransport(result: .success((Data(), 200)))
    let service = GroupCallProofService(transport: transport)
    await #expect(throws: GroupCallProofService.Failure.self) {
        try await service.fetchToken(
            cdnBaseURL: URL(string: "http://cdn.signal.org")!,
            authorization: sampleAuthorization,
            groupIdHex: "abcd"
        )
    }
    // Nothing may be sent over an unauthenticated transport.
    #expect(transport.lastRequest == nil)
}

// MARK: - Credential decoding

@Test func decodesTheTokenField() {
    let payload: [UInt8] = [0xde, 0xad, 0xbe, 0xef, 0x00, 0x7f]
    #expect(ExternalGroupCredential.decodeToken(from: encodedTokenField(payload)) == payload)
}

@Test func decodesAnEmptyToken() {
    #expect(ExternalGroupCredential.decodeToken(from: encodedTokenField([])) == [])
}

@Test func decodesATokenLongerThanOneVarintByte() {
    let payload = [UInt8](repeating: 0x5a, count: 300)
    #expect(ExternalGroupCredential.decodeToken(from: encodedTokenField(payload)) == payload)
}

@Test func skipsUnknownFieldsBeforeTheToken() {
    var data = encodedTokenField([9, 9, 9])
    // Prepend field 2, varint, value 1: tag 0x10.
    data = Data([0x10, 0x01] + [UInt8](data))
    #expect(ExternalGroupCredential.decodeToken(from: data) == [9, 9, 9])
}

@Test func rejectsMalformedCredentials() {
    let bad: [Data] = [
        Data(),                          // empty
        Data([0x0a]),                    // truncated length
        Data([0x0a, 0x05, 0x01]),        // length exceeds body
        Data([0x0a, 0xff, 0xff, 0xff, 0xff, 0xff]), // runaway varint
        Data([0x0a, 0x01]),              // length 1 but no body byte
        Data([0x08, 0x01]),              // token field with the wrong wire type
        Data([0x0b, 0x00]),              // unsupported wire type
        Data([0x0a, 0x80]),              // multi-byte length that never arrives
    ]
    for data in bad {
        #expect(ExternalGroupCredential.decodeToken(from: data) == nil)
    }
}

@Test func fieldsAfterTheTokenAreIgnoredAsProtobufRequires() {
    // A peer may append fields this build does not know about. Rejecting them
    // would be stricter than the wire format allows; the SFU still validates
    // the token, so a mis-read token fails at the join rather than being
    // trusted.
    let trailing = encodedTokenField([0x41]) + Data([0x10, 0x01])
    #expect(ExternalGroupCredential.decodeToken(from: trailing) == [0x41])
}

// MARK: - Failure handling

@Test func serverErrorsAreReportedWithoutEchoingTheBody() async {
    // A rejected presentation answers 401 with a body that can contain request
    // material. It must surface as a status, not as text.
    let leaky = Data("authorization=00a1b2c3:4d5e secret".utf8)
    let transport = RecordingTransport(result: .success((leaky, 401)))
    let service = GroupCallProofService(transport: transport)

    let error = await #expect(throws: GroupCallProofService.Failure.self) {
        try await service.fetchToken(
            cdnBaseURL: URL(string: "https://cdn.signal.org")!,
            authorization: sampleAuthorization,
            groupIdHex: "abcd"
        )
    }
    guard case .unexpectedStatus(let code) = error else {
        Issue.record("expected an unexpectedStatus failure, got \(error)")
        return
    }
    #expect(code == 401)
    #expect(!String(describing: error).contains("00a1b2c3"))
}

@Test func oversizedResponsesAreRefused() async {
    let huge = Data(repeating: 0x41, count: GroupCallProofService.maxResponseBytes + 1)
    let transport = RecordingTransport(result: .success((huge, 200)))
    let service = GroupCallProofService(transport: transport)

    await #expect(throws: GroupCallProofService.Failure.self) {
        try await service.fetchToken(
            cdnBaseURL: URL(string: "https://cdn.signal.org")!,
            authorization: sampleAuthorization,
            groupIdHex: "abcd"
        )
    }
}

@Test func aBodyWithoutATokenIsRejected() async {
    let transport = RecordingTransport(result: .success((Data([0x10, 0x01]), 200)))
    let service = GroupCallProofService(transport: transport)

    await #expect(throws: GroupCallProofService.Failure.malformedCredential) {
        try await service.fetchToken(
            cdnBaseURL: URL(string: "https://cdn.signal.org")!,
            authorization: sampleAuthorization,
            groupIdHex: "abcd"
        )
    }
}

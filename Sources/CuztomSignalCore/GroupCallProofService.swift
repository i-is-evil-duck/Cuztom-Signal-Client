import Foundation

/// Fetches a Signal group-call membership proof from the CDN.
///
/// A membership proof is what lets RingRTC join an SFU room, and it is a
/// short-lived credential. The flow, traced from Signal Desktop:
///
/// 1. Rust derives the group's ZK identity and presents a server-issued auth
///    credential, producing the authorization string
///    `hex(group public params) + ":" + hex(presentation)`.
/// 2. This service redeems it: `GET {cdn}/v2/groups/token` with
///    `Authorization: Basic base64(<that string>)`.
/// 3. The CDN answers with a protobuf `ExternalGroupCredential { string token }`.
///
/// The authorization string and the resulting token are both secret. Neither is
/// ever logged, and both are held only for as long as the call that needs them.
public struct GroupCallProofService: Sendable {
    /// CDN path that redeems a ZK group presentation for a call token.
    public static let tokenPath = "v2/groups/token"

    /// A CDN response is a single small protobuf message. Cap the body so a
    /// broken or hostile endpoint cannot make us allocate arbitrarily.
    public static let maxResponseBytes = 64 * 1024

    /// The group id, hex, is carried alongside so the caller can correlate a
    /// proof with the group it belongs to without logging either value.
    public struct Proof: Sendable, Equatable {
        public let groupIdHex: String
        public let token: [UInt8]
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case invalidAuthorization
        case invalidCDNHost(String)
        case unexpectedStatus(Int)
        case responseTooLarge(Int)
        case malformedCredential

        public var errorDescription: String? {
            switch self {
            case .invalidAuthorization:
                return "Group call authorization value is not valid base64-safe hex"
            case .invalidCDNHost:
                return "CDN host is not a valid https URL"
            case .unexpectedStatus(let code):
                return "CDN returned HTTP \(code) for the group call token request"
            case .responseTooLarge(let limit):
                return "CDN response exceeded the \(limit) byte limit"
            case .malformedCredential:
                return "CDN response was not a valid group call credential"
            }
        }
    }

    /// Seam so tests can exercise the request and decoding without a network.
    public protocol Transport: Sendable {
        func send(_ request: URLRequest) async throws -> (Data, Int)
    }

    private let transport: any Transport
    private let session: URLSession

    /// Uses a real HTTPS session.
    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        // Group call credentials must never be written to a shared cache.
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        self.session = URLSession(configuration: configuration)
        self.transport = URLSessionTransport(session: session)
    }

    public init(transport: any Transport) {
        self.transport = transport
        self.session = URLSession(configuration: .ephemeral)
    }

    /// Redeem an authorization string for a call token.
    ///
    /// - Parameters:
    ///   - cdnBaseURL: a CDN root such as `https://cdn.signal.org`.
    ///   - authorization: `hex(group public params) + ":" + hex(presentation)`,
    ///     produced by the native core.
    ///   - groupIdHex: the group's ZK id in hex, for correlation only.
    public func fetchToken(
        cdnBaseURL: URL,
        authorization: String,
        groupIdHex: String
    ) async throws -> Proof {
        let basic = try Self.basicAuthorizationValue(authorization)

        guard var components = URLComponents(
            url: cdnBaseURL.appendingPathComponent(Self.tokenPath),
            resolvingAgainstBaseURL: false
        ), components.scheme?.lowercased() == "https", components.host != nil else {
            throw Failure.invalidCDNHost(cdnBaseURL.absoluteString)
        }
        components.query = nil
        guard let url = components.url else {
            throw Failure.invalidCDNHost(cdnBaseURL.absoluteString)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-protobuf", forHTTPHeaderField: "Accept")
        request.setValue("application/x-protobuf", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.httpBody = nil

        let (data, status) = try await transport.send(request)
        guard (200..<300).contains(status) else {
            // The body may contain a server diagnostic, but it can also echo
            // request material, so it is deliberately not surfaced.
            throw Failure.unexpectedStatus(status)
        }
        guard data.count <= Self.maxResponseBytes else {
            throw Failure.responseTooLarge(Self.maxResponseBytes)
        }
        guard let token = ExternalGroupCredential.decodeToken(from: data),
              !token.isEmpty else {
            throw Failure.malformedCredential
        }
        return Proof(groupIdHex: groupIdHex, token: token)
    }

    /// `hex(groupPublicParams) + ":" + hex(presentation)` base64-encoded, with
    /// the trailing newline the presentation may carry removed.
    static func basicAuthorizationValue(_ authorization: String) throws -> String {
        // The ZK presentation is a fixed-width byte structure; reject anything
        // that is not the two-hex-halves form before putting it on the wire.
        let parts = authorization.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isHexDigit) }) else {
            throw Failure.invalidAuthorization
        }
        return Data(authorization.utf8).base64EncodedString()
    }
}

/// The one message the CDN returns: `ExternalGroupCredential { string token = 1 }`.
///
/// Decoded by hand rather than pulling in a protobuf runtime: this is a single
/// length-delimited field, and a strict decoder is smaller than the dependency
/// and fails closed on anything unexpected.
enum ExternalGroupCredential {
    private static let tokenField: UInt32 = 1
    private static let lengthDelimited: UInt32 = 2

    static func decodeToken(from data: Data) -> [UInt8]? {
        var reader = Reader(data: data)
        while let tag = reader.readVarint() {
            let field = tag >> 3
            let wireType = tag & 0x7
            switch (field, wireType) {
            case (tokenField, lengthDelimited):
                guard let length = reader.readVarint(), length <= reader.remaining else {
                    return nil
                }
                // Fields after the token are ignored, as protobuf requires: a
                // peer may append fields this build does not know about. The
                // SFU is the authority on whether the token is actually valid,
                // so a locally mis-read token fails at the join rather than
                // being silently trusted.
                return reader.readBytes(Int(length))
            case (_, 0):
                guard reader.readVarint() != nil else { return nil }
            case (_, 1):
                guard reader.skip(8) else { return nil }
            case (_, 5):
                guard reader.skip(4) else { return nil }
            default:
                // Groups (3/4) and unknown wire types are not expected here.
                return nil
            }
        }
        // Well-formed bytes that never contained a token field.
        return nil
    }

    private struct Reader {
        private let bytes: [UInt8]
        private var offset = 0

        init(data: Data) { self.bytes = [UInt8](data) }

        var remaining: Int { bytes.count - offset }

        mutating func readVarint() -> UInt32? {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while shift < 64 {
                guard offset < bytes.count else { return nil }
                let byte = bytes[offset]
                offset += 1
                result |= UInt64(byte & 0x7f) << shift
                if byte & 0x80 == 0 { return UInt32(truncatingIfNeeded: result) }
                shift += 7
            }
            return nil
        }

        mutating func readBytes(_ count: Int) -> [UInt8]? {
            guard count >= 0, count <= remaining else { return nil }
            let slice = Array(bytes[offset..<(offset + count)])
            offset += count
            return slice
        }

        mutating func skip(_ count: Int) -> Bool {
            guard count <= remaining else { return false }
            offset += count
            return true
        }
    }
}

/// Real network transport.
struct URLSessionTransport: GroupCallProofService.Transport {
    let session: URLSession

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (data, status)
    }
}

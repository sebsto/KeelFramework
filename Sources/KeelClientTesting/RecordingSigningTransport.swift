public import KeelCore

#if canImport(FoundationEssentials)
public import FoundationEssentials
#else
public import Foundation
#endif

// MARK: - Credentials

/// AWS IAM credentials used by ``KeelSigV4Transport`` to sign requests.
///
/// All three fields are required for request signing. When `sessionToken` is
/// non-nil it is included in the signed headers (`x-amz-security-token`).
public struct AWSCredentials: Sendable {
    public let accessKeyId: String
    public let secretAccessKey: String
    public let sessionToken: String?

    public init(accessKeyId: String, secretAccessKey: String, sessionToken: String? = nil) {
        self.accessKeyId = accessKeyId
        self.secretAccessKey = secretAccessKey
        self.sessionToken = sessionToken
    }
}

// MARK: - Real SigV4 transport (Apple / CryptoKit only)

#if canImport(CryptoKit)
import CryptoKit

/// A reference `HTTPTransport` that signs outgoing requests with AWS SigV4.
///
/// This type lives in `KeelClientTesting` so that app test targets can wire a real,
/// deterministic signer without pulling a crypto dependency into `KeelCore` or into
/// shipped production code. `KeelCore` stays dependency-free; only `CryptoKit`
/// (part of the Apple platform SDK) is needed here.
///
/// ### Conditional signing
///
/// Signing is performed **only when credentials are provided**. If `credentials` is
/// `nil` the request is forwarded to the underlying transport unchanged and unsigned.
/// This is load-bearing for public routes such as `/v1/bootstrap` and `/v1/stats`
/// (CDK `authorizationType: NONE`) that must work offline and signed-out.
///
/// ### Injectable clock
///
/// The `date` closure is called once per request and defaults to `{ Date() }`. Override
/// it in tests to produce deterministic `x-amz-date` / `dateStamp` values and reproduce
/// a golden signature byte-for-byte.
///
/// ### Session token
///
/// When `credentials.sessionToken` is non-nil it is added to the request headers as
/// `x-amz-security-token` **and** included in `SignedHeaders`. Omitting a present
/// session token causes a signature mismatch at API Gateway.
///
/// ### Signing invariant
///
/// The signer receives the `HTTPRequestData` exactly as `BackendClient` built it — no
/// header or body mutation before the canonical request is computed. Any change to the
/// request before signing invalidates the signature.
///
/// ### Usage
///
/// ```swift
/// let transport = KeelSigV4Transport(
///     inner: URLSessionTransport(),
///     credentials: AWSCredentials(
///         accessKeyId: credentials.accessKeyId,
///         secretAccessKey: credentials.secretAccessKey,
///         sessionToken: credentials.sessionToken),
///     region: "eu-central-1")
///
/// let client = BackendClient(
///     baseURL: URL(string: "https://api.example.com")!,
///     authorization: .none,   // transport owns all authorization
///     transport: transport)
/// ```
public struct KeelSigV4Transport: HTTPTransport {

    private let inner: any HTTPTransport
    private let credentials: AWSCredentials?
    private let region: String
    private let service: String
    private let date: @Sendable () -> Date

    /// Create a signing transport.
    ///
    /// - Parameters:
    ///   - inner: The underlying transport used to actually send the (optionally signed)
    ///     request. Typically `URLSessionTransport()` in production; a `FakeTransport` in tests.
    ///   - credentials: Optional IAM credentials. Pass `nil` (or omit) for public routes —
    ///     requests are forwarded unsigned.
    ///   - region: AWS region that hosts the API Gateway (e.g. `"eu-central-1"`).
    ///   - service: AWS service identifier. Defaults to `"execute-api"`.
    ///   - date: Clock override. Defaults to `Date()`. Inject a fixed date in tests to produce
    ///     a deterministic signature.
    public init(
        inner: any HTTPTransport,
        credentials: AWSCredentials? = nil,
        region: String,
        service: String = "execute-api",
        date: @Sendable @escaping () -> Date = { Date() }
    ) {
        self.inner = inner
        self.credentials = credentials
        self.region = region
        self.service = service
        self.date = date
    }

    public func send(_ request: HTTPRequestData) async throws -> HTTPResponseData {
        guard let creds = credentials else {
            // No credentials — forward unsigned (public NONE routes).
            return try await inner.send(request)
        }

        let now = date()
        let dateLong = isoLong(now)  // "20250902T080000Z"
        let dateShort = isoShort(now)  // "20250902"

        let bodyData = request.body ?? Data()
        let bodyHash = SHA256.hash(data: bodyData).hexString

        // Build the header map that will be signed.
        // Start from the request's existing headers so Content-Type etc. are preserved.
        //
        // For execute-api (API Gateway IAM auth) the signed set is host + x-amz-date
        // (+ x-amz-security-token when a session token is present). The payload hash is
        // carried in the final line of the canonical request; x-amz-content-sha256 is an
        // S3-ism and is deliberately NOT added to the signed headers here — adding it would
        // change SignedHeaders and therefore the signature.
        var headers = request.headers
        headers["host"] = request.url.host ?? ""
        headers["x-amz-date"] = dateLong
        if let token = creds.sessionToken {
            headers["x-amz-security-token"] = token
        }

        // Canonical request — signed header names sorted lexicographically.
        let signedHeaderNames = headers.keys.sorted()
        let canonicalHeaders =
            signedHeaderNames
            .map { "\($0):\(headers[$0]!)" }
            .joined(separator: "\n") + "\n"
        let signedHeadersStr = signedHeaderNames.joined(separator: ";")
        let canonicalURI = request.url.path.isEmpty ? "/" : request.url.path
        let canonicalQuery = canonicalQueryString(from: request.url)

        let canonicalRequest = [
            request.method.rawValue,
            canonicalURI,
            canonicalQuery,
            canonicalHeaders,
            signedHeadersStr,
            bodyHash,
        ].joined(separator: "\n")

        // String to sign.
        let scope = "\(dateShort)/\(region)/\(service)/aws4_request"
        let stringToSign =
            "AWS4-HMAC-SHA256\n\(dateLong)\n\(scope)\n"
            + SHA256.hash(data: Data(canonicalRequest.utf8)).hexString

        // Derived signing key.
        let signingKey = deriveKey(
            secret: creds.secretAccessKey,
            date: dateShort,
            region: region,
            service: service)
        let signature = HMAC<SHA256>.authenticationCode(
            for: Data(stringToSign.utf8),
            using: signingKey
        ).hexString

        // Authorization header.
        headers["authorization"] =
            "AWS4-HMAC-SHA256 Credential=\(creds.accessKeyId)/\(scope),"
            + " SignedHeaders=\(signedHeadersStr),"
            + " Signature=\(signature)"

        // Forward the signed request.
        var signed = request
        signed.headers = headers
        return try await inner.send(signed)
    }

    // MARK: - Private helpers

    private func deriveKey(
        secret: String, date: String, region: String, service: String
    ) -> SymmetricKey {
        let kDate = HMAC<SHA256>.authenticationCode(
            for: Data(date.utf8),
            using: SymmetricKey(data: Data(("AWS4" + secret).utf8)))
        let kRegion = HMAC<SHA256>.authenticationCode(
            for: Data(region.utf8),
            using: SymmetricKey(data: Data(kDate)))
        let kService = HMAC<SHA256>.authenticationCode(
            for: Data(service.utf8),
            using: SymmetricKey(data: Data(kRegion)))
        let kSigning = HMAC<SHA256>.authenticationCode(
            for: Data("aws4_request".utf8),
            using: SymmetricKey(data: Data(kService)))
        return SymmetricKey(data: Data(kSigning))
    }

    private func canonicalQueryString(from url: URL) -> String {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let items = comps.queryItems, !items.isEmpty
        else { return "" }
        return
            items
            .map { (rfc3986Encode($0.name), rfc3986Encode($0.value ?? "")) }
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: "&")
    }

    /// RFC 3986 percent-encoding as required by AWS SigV4 (encodes more characters
    /// than Swift's `.urlQueryAllowed`).
    private func rfc3986Encode(_ string: String) -> String {
        let allowed = CharacterSet(
            charactersIn:
                "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }

    private func isoShort(_ d: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d%02d%02d", c.year!, c.month!, c.day!)
    }

    private func isoLong(_ d: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
        return String(
            format: "%04d%02d%02dT%02d%02d%02dZ",
            c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
    }
}

private extension Digest {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

private extension MessageAuthenticationCode {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

#endif  // canImport(CryptoKit)

// MARK: - Recording transport (available on all platforms)

/// A test double for an app-owned SigV4 (or any signing) transport.
///
/// Wraps a `FakeTransport` and records every request that passes through `send(_:)`.
/// Available on all platforms (no CryptoKit required). Use this in tests that only need
/// to verify the `BackendClient` → transport wiring, not the signature value itself.
///
/// For a real signature assertion use ``KeelSigV4Transport`` (Apple/CryptoKit-gated).
///
/// ### Typical usage
///
/// ```swift
/// let recording = RecordingSigningTransport(wrapping: FakeTransport())
/// await recording.inner.respond(to: "/v1/ping", body: #"{"ok":true}"#)
///
/// let client = BackendClient(
///     baseURL: URL(string: "https://api.example.com")!,
///     authorization: .none,
///     transport: recording)
/// await client.send(ping: myPing)
///
/// let requests = await recording.requests
/// #expect(!requests.isEmpty)
/// #expect(requests.first?.headers["authorization"] == nil)  // client adds no auth header
/// ```
public actor RecordingSigningTransport: HTTPTransport {
    /// The underlying fake that supplies canned responses.
    public let inner: FakeTransport

    /// Every request received by `send(_:)`, in order.
    public private(set) var requests: [HTTPRequestData] = []

    /// Back-compat alias: same as `requests`. Deprecated — use `requests` directly.
    @available(*, deprecated, renamed: "requests")
    public var signed: [HTTPRequestData] { requests }

    public init(wrapping inner: FakeTransport = FakeTransport()) {
        self.inner = inner
    }

    public func send(_ request: HTTPRequestData) async throws -> HTTPResponseData {
        requests.append(request)
        return try await inner.send(request)
    }
}

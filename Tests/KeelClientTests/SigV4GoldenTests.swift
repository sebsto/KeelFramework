// These tests exercise a real HMAC-SHA256 signer and are therefore Apple-only
// (CryptoKit is unavailable on Linux). CI runs them on the macOS runner.
#if canImport(CryptoKit)
import CryptoKit
import Foundation
import KeelCore
import KeelClientTesting
import Testing

/// Golden-signature tests for ``KeelSigV4Transport``.
///
/// The pinned inputs and expected outputs below are the single source of truth for
/// the reference transport. They match the vector in `docs/G4-REVISION.md` and the
/// IAM transport contract section of `docs/INTEGRATION.md`.
///
/// All values are fixed so the tests are purely deterministic — no network, no
/// clock, no credentials from the environment.
@Suite("SigV4 golden signature")
struct SigV4GoldenTests {

    // MARK: - Pinned inputs

    /// Clock injected into the signer.  "2025-09-02T08:00:00Z"
    static let fixedDate: Date = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(
            from: DateComponents(
                timeZone: TimeZone(identifier: "UTC")!,
                year: 2025, month: 9, day: 2,
                hour: 8, minute: 0, second: 0))!
    }()

    static let accessKeyId = "AKIDEXAMPLE"
    static let secretAccessKey = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
    // No session token in this vector.

    static let region = "eu-central-1"
    static let service = "execute-api"
    static let host = "api.example.com"
    static let path = "/v1/ping"
    static let body = Data(#"{"schemaVersion":1}"#.utf8)

    // MARK: - Expected values (from the spec)

    static let expectedPayloadHash =
        "0e9561cfb83d50990a103b3896fe249a11fe27fa28985448187f93ec12116d72"

    static let expectedCanonicalRequest = """
        POST
        /v1/ping

        host:api.example.com
        x-amz-date:20250902T080000Z

        host;x-amz-date
        0e9561cfb83d50990a103b3896fe249a11fe27fa28985448187f93ec12116d72
        """

    static let expectedStringToSign = """
        AWS4-HMAC-SHA256
        20250902T080000Z
        20250902/eu-central-1/execute-api/aws4_request
        7294d5993783d0ab5cdf719a50ffeabbab1e00beaf526a094ececffaf9d51848
        """

    static let expectedSignature =
        "91edb29d32b6cd7542559f8344cbd6887c368bc34dd6d6dcb7639f3f9b38d547"

    static let expectedAuthorization =
        "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20250902/eu-central-1/execute-api/aws4_request,"
        + " SignedHeaders=host;x-amz-date,"
        + " Signature=91edb29d32b6cd7542559f8344cbd6887c368bc34dd6d6dcb7639f3f9b38d547"

    // MARK: - Helpers

    /// Build a signed request using the pinned inputs and capture the result via FakeTransport.
    private func signedRequest() async throws -> HTTPRequestData {
        let fake = FakeTransport()
        await fake.respond(to: Self.path, body: #"{"ok":true}"#)

        let transport = KeelSigV4Transport(
            inner: fake,
            credentials: AWSCredentials(
                accessKeyId: Self.accessKeyId,
                secretAccessKey: Self.secretAccessKey),
            region: Self.region,
            service: Self.service,
            date: { Self.fixedDate })

        let request = HTTPRequestData(
            method: .post,
            url: URL(string: "https://\(Self.host)\(Self.path)")!,
            headers: [:],
            body: Self.body)

        _ = try await transport.send(request)
        let sent = await fake.requests
        return try #require(sent.last)
    }

    // MARK: - Tests

    /// The signer must produce exactly the golden `Signature=` hex value.
    @Test("Golden signature matches pinned vector")
    func goldenSignature() async throws {
        let sent = try await signedRequest()

        let authorization = try #require(
            sent.headers["authorization"],
            "Expected an Authorization header to be present")

        // Extract just the Signature= component for a tight assertion.
        let signaturePrefix = "Signature="
        let parts = authorization.components(separatedBy: ", ")
        let signaturePart = try #require(
            parts.first(where: { $0.hasPrefix(signaturePrefix) }),
            "No 'Signature=' field in Authorization header: \(authorization)")
        let signature = String(signaturePart.dropFirst(signaturePrefix.count))

        #expect(
            signature == Self.expectedSignature,
            """
            SigV4 signature mismatch.
            Expected: \(Self.expectedSignature)
            Got:      \(signature)
            Full Authorization header: \(authorization)
            """)
    }

    /// Verify the complete Authorization header matches the pinned value, not just
    /// the Signature= fragment.
    @Test("Full Authorization header matches pinned vector")
    func fullAuthorizationHeader() async throws {
        let sent = try await signedRequest()
        let authorization = try #require(sent.headers["authorization"])
        #expect(
            authorization == Self.expectedAuthorization,
            """
            Authorization header mismatch.
            Expected: \(Self.expectedAuthorization)
            Got:      \(authorization)
            """)
    }

    /// Pin the payload hash so a body-encoding change surfaces immediately.
    @Test("Payload SHA-256 matches pinned vector")
    func payloadHash() async throws {
        let digest = SHA256.hash(data: Self.body)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        #expect(hex == Self.expectedPayloadHash)
    }

    /// Pin the x-amz-date header so the injected-clock path is exercised.
    @Test("x-amz-date is derived from the injected clock")
    func amzDateHeader() async throws {
        let sent = try await signedRequest()
        #expect(sent.headers["x-amz-date"] == "20250902T080000Z")
    }

    /// Signed headers must be exactly `host;x-amz-date` for this no-token vector.
    @Test("SignedHeaders is host;x-amz-date for a no-session-token request")
    func signedHeadersField() async throws {
        let sent = try await signedRequest()
        let auth = try #require(sent.headers["authorization"])
        #expect(auth.contains("SignedHeaders=host;x-amz-date,"))
    }

    // MARK: - Public-route guarantee

    /// The most important invariant: when no credentials are provided the request
    /// MUST go through unsigned. Public routes such as /v1/bootstrap and /v1/stats
    /// (CDK authorizationType: NONE) must work offline and signed-out.
    @Test("Request is unsigned when credentials are nil (public-route guarantee)")
    func unsignedWhenNoCredentials() async throws {
        let fake = FakeTransport()
        await fake.respond(to: Self.path, body: #"{"ok":true}"#)

        let transport = KeelSigV4Transport(
            inner: fake,
            credentials: nil,  // <- no credentials
            region: Self.region,
            service: Self.service,
            date: { Self.fixedDate })

        let request = HTTPRequestData(
            method: .post,
            url: URL(string: "https://\(Self.host)\(Self.path)")!,
            headers: [:],
            body: Self.body)

        _ = try await transport.send(request)
        let sent = await fake.requests
        let received = try #require(sent.last)

        #expect(
            received.headers["authorization"] == nil,
            "Transport must NOT add an Authorization header when credentials are nil")
        #expect(
            received.headers["x-amz-date"] == nil,
            "Transport must NOT add x-amz-date when credentials are nil")
        #expect(
            received.headers["x-amz-content-sha256"] == nil,
            "Transport must NOT add x-amz-content-sha256 when credentials are nil")
    }

    // MARK: - Session-token signing

    /// When a session token is present it must appear in SignedHeaders.
    /// (Full golden vector with a token is not pinned here because the token
    /// changes the derived signing key and canonical request — a future spec
    /// update can add the vector. This test asserts the structural requirement.)
    @Test("x-amz-security-token is included in SignedHeaders when session token present")
    func sessionTokenIsSigned() async throws {
        let fake = FakeTransport()
        await fake.respond(to: Self.path, body: #"{"ok":true}"#)

        let transport = KeelSigV4Transport(
            inner: fake,
            credentials: AWSCredentials(
                accessKeyId: Self.accessKeyId,
                secretAccessKey: Self.secretAccessKey,
                sessionToken: "EXAMPLESESSIONTOKEN"),
            region: Self.region,
            service: Self.service,
            date: { Self.fixedDate })

        let request = HTTPRequestData(
            method: .post,
            url: URL(string: "https://\(Self.host)\(Self.path)")!,
            headers: [:],
            body: Self.body)

        _ = try await transport.send(request)
        let sent = await fake.requests
        let received = try #require(sent.last)

        let auth = try #require(
            received.headers["authorization"],
            "Authorization header must be present when session token is provided")

        #expect(
            received.headers["x-amz-security-token"] == "EXAMPLESESSIONTOKEN",
            "x-amz-security-token header must be forwarded")
        #expect(
            auth.contains("x-amz-security-token"),
            "x-amz-security-token must appear in SignedHeaders: \(auth)")
    }
}
#endif  // canImport(CryptoKit)

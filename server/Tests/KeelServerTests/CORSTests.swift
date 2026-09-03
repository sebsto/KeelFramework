import Testing

@testable import KeelRouter

/// Tests for `CORSConfig` — the matching and allowlist logic that governs whether and
/// which `Access-Control-Allow-Origin` header the router emits.
///
/// The three rules from the spec:
///   1. Echo the request `Origin` only if it is in the allowlist; never `*`.
///   2. No allowlist / no match → no CORS header (tested here as a `nil` return).
///   3. Preflight and error paths are also covered by the matching contract.
///
/// Router-level integration (actual HTTP round-trips checking the header on success and
/// error responses, and OPTIONS preflight) is verified by the CI test suite on a Mac
/// where the full lambda-kit Routing package can run.
@Suite("CORSConfig — allowlist matching")
struct CORSTests {

    // MARK: - Allowlist matching

    @Test("An origin that is in the allowlist is echoed back")
    func matchedOriginIsEchoed() {
        let cors = CORSConfig(allowedOrigins: ["https://example.com", "https://www.example.com"])
        #expect(cors.match("https://example.com") == "https://example.com")
        #expect(cors.match("https://www.example.com") == "https://www.example.com")
    }

    @Test("An origin not in the allowlist returns nil (no CORS header)")
    func disallowedOriginIsRejected() {
        let cors = CORSConfig(allowedOrigins: ["https://example.com"])
        #expect(cors.match("https://evil.com") == nil)
        #expect(cors.match("https://notexample.com") == nil)
        // Subdomain is a different origin; a suffix match would be a security hole.
        #expect(cors.match("https://subdomain.example.com") == nil)
    }

    @Test("Apex and www are distinct entries — listing one does not match the other")
    func apexAndWwwAreDistinct() {
        let corsApexOnly = CORSConfig(allowedOrigins: ["https://example.com"])
        #expect(corsApexOnly.match("https://www.example.com") == nil)

        let corsWwwOnly = CORSConfig(allowedOrigins: ["https://www.example.com"])
        #expect(corsWwwOnly.match("https://example.com") == nil)

        // Both listed: both match.
        let corsBoth = CORSConfig(allowedOrigins: [
            "https://example.com",
            "https://www.example.com",
        ])
        #expect(corsBoth.match("https://example.com") == "https://example.com")
        #expect(corsBoth.match("https://www.example.com") == "https://www.example.com")
    }

    @Test("An empty allowlist disables CORS — any origin returns nil")
    func emptyAllowlistDisablesCORS() {
        let cors = CORSConfig(allowedOrigins: [])
        #expect(cors.match("https://example.com") == nil)
        #expect(cors.match("https://evil.com") == nil)
    }

    @Test("A nil origin (non-cross-origin request) always returns nil")
    func nilOriginReturnsNil() {
        let cors = CORSConfig(allowedOrigins: ["https://example.com"])
        #expect(cors.match(nil) == nil)
    }

    @Test(".disabled is identical to an empty allowlist")
    func disabledConfig() {
        #expect(CORSConfig.disabled.match("https://example.com") == nil)
        #expect(CORSConfig.disabled.match(nil) == nil)
    }

    // MARK: - Wildcard is never emitted

    @Test("The matched value is always the specific origin, never *")
    func neverWildcard() {
        let cors = CORSConfig(allowedOrigins: ["https://example.com"])
        let result = cors.match("https://example.com")
        #expect(result != "*")
        #expect(result == "https://example.com")
    }

    // MARK: - Multiple origins

    @Test("All listed origins are individually matchable")
    func multipleOriginsAllMatch() {
        let origins = ["https://a.com", "https://b.com", "https://c.com"]
        let cors = CORSConfig(allowedOrigins: origins)
        for origin in origins {
            #expect(cors.match(origin) == origin)
        }
    }

    @Test("An origin not in a multi-entry allowlist is rejected")
    func multipleOriginsRejectUnknown() {
        let cors = CORSConfig(
            allowedOrigins: ["https://a.com", "https://b.com", "https://c.com"])
        #expect(cors.match("https://d.com") == nil)
    }

    // MARK: - Preflight Allow-Headers (SigV4 / IAM route support)

    // The router registers an OPTIONS preflight for every route, including the AWS_IAM
    // `/v1/ping` route. A browser signing that route with SigV4 must be allowed to send the
    // `X-Amz-*` headers, or the preflight it has to clear first would reject them. These pin
    // the advertised set so a future edit that drops one breaks here instead of in a browser.

    @Test("Preflight Allow-Headers advertises the SigV4 headers an IAM route needs")
    func preflightAllowsSigV4Headers() {
        let advertised = Self.advertisedAllowHeaders()
        for required in ["authorization", "x-amz-date", "x-amz-security-token"] {
            #expect(
                advertised.contains(required),
                "Preflight Allow-Headers must include \(required) so a browser can preflight a SigV4-signed IAM route"
            )
        }
    }

    @Test("Preflight Allow-Headers keeps Content-Type for JSON bodies")
    func preflightAllowsContentType() {
        #expect(Self.advertisedAllowHeaders().contains("content-type"))
    }

    /// Parse the comma-separated Allow-Headers value into a lowercased, whitespace-free set.
    /// Stdlib only — this test target does not import Foundation.
    private static func advertisedAllowHeaders() -> Set<String> {
        Set(
            KeelRouter.preflightAllowHeaders
                .lowercased()
                .split(separator: ",")
                .map { String($0.filter { !$0.isWhitespace }) })
    }
}

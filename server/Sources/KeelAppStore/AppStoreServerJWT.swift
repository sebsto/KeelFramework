import Crypto

#if canImport(FoundationEssentials)
public import FoundationEssentials
#else
public import Foundation
#endif

// MARK: - AppStoreServerJWT

/// Signs and caches the ES256 bearer token for Apple's App Store Server API.
///
/// Ported from odvpn's `VPNBilling.AppStoreServerJWT` — generic App Store Connect plumbing
/// with nothing consumables- or credits-specific in it, so it lifts out cleanly. Apps that
/// never *call* Apple's API (only receive its notifications) never link it.
///
/// Carries the App Store Server API's claim set: `aud` is `appstoreconnect-v1`, `bid` pins the
/// token to one app's bundle, and `exp` is explicit — Apple rejects a token whose lifetime
/// exceeds 60 minutes.
///
/// `maxAge` defaults to 20 minutes against a 30-minute `exp`, so a cached token is always
/// re-signed with at least 10 minutes of validity left. That margin matters: the token is
/// minted before an outbound HTTPS call, and a token that expires mid-flight returns 401 with
/// no way to distinguish it from a bad key.
///
/// Actor-isolated because the cache is mutable shared state; the clock is injectable so tests
/// exercise expiry without waiting.
public actor AppStoreServerJWT {
    /// Apple's fixed audience for App Store Server API tokens.
    static let audience = "appstoreconnect-v1"

    private let signingKey: P256.Signing.PrivateKey
    private let keyID: String
    private let issuerID: String
    private let bundleID: String
    private let clock: @Sendable () -> Date
    /// How long a cached token is reused before being re-signed.
    private let maxAge: TimeInterval
    /// The `exp - iat` lifetime stamped into each token. Apple's cap is 60 minutes.
    private let lifetime: TimeInterval

    private var cached: (token: String, issuedAt: Date)?

    public init(
        p8PEM: String,
        keyID: String,
        issuerID: String,
        bundleID: String,
        maxAge: TimeInterval = 1200,  // 20 min
        lifetime: TimeInterval = 1800,  // 30 min, well under Apple's 60 min cap
        clock: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        self.signingKey = try P256.Signing.PrivateKey(pemRepresentation: p8PEM)
        self.keyID = keyID
        self.issuerID = issuerID
        self.bundleID = bundleID
        self.maxAge = maxAge
        self.lifetime = lifetime
        self.clock = clock
    }

    /// Returns a valid bearer token, re-signing only when the cached one has aged past `maxAge`.
    public func token() throws -> String {
        let now = clock()
        if let cached, now.timeIntervalSince(cached.issuedAt) < maxAge {
            return cached.token
        }
        let token = try sign(iat: now)
        cached = (token, now)
        return token
    }

    // MARK: - Signing

    private struct JWTHeader: Encodable {
        let alg: String
        let kid: String
        let typ: String
    }

    private struct JWTClaims: Encodable {
        let iss: String
        let iat: Int
        let exp: Int
        let aud: String
        let bid: String
    }

    private func sign(iat: Date) throws -> String {
        let issuedAt = Int(iat.timeIntervalSince1970)
        let header = JWTHeader(alg: "ES256", kid: keyID, typ: "JWT")
        let claims = JWTClaims(
            iss: issuerID,
            iat: issuedAt,
            exp: issuedAt + Int(lifetime),
            aud: Self.audience,
            bid: bundleID)

        let headerSegment = try Base64URL.encodeJSON(header)
        let claimsSegment = try Base64URL.encodeJSON(claims)
        let signingInput = "\(headerSegment).\(claimsSegment)"

        let signature = try signingKey.signature(for: Data(signingInput.utf8))
        let signatureSegment = Base64URL.encode(signature.rawRepresentation)
        return "\(signingInput).\(signatureSegment)"
    }
}

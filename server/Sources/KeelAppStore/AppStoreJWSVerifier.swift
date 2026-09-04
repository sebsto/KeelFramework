public import X509

#if canImport(FoundationEssentials)
public import FoundationEssentials
#else
public import Foundation
#endif

/// The trusted payload of a verified StoreKit-2 `Transaction.jwsRepresentation`.
public struct VerifiedTransaction: Sendable, Equatable {
    public let bundleId: String
    public let productId: String
    public let transactionId: String
    public let originalTransactionId: String
    public let purchaseDate: Date

    /// `"Sandbox"` or `"Production"`, Apple's casing kept.
    public let environment: String

    /// When the subscription period ends, for auto-renewables. Nil for non-consumables,
    /// which is what makes such a purchase permanent.
    public let expiresDate: Date?

    public init(
        bundleId: String,
        productId: String,
        transactionId: String,
        originalTransactionId: String,
        purchaseDate: Date,
        environment: String,
        expiresDate: Date? = nil
    ) {
        self.bundleId = bundleId
        self.productId = productId
        self.transactionId = transactionId
        self.originalTransactionId = originalTransactionId
        self.purchaseDate = purchaseDate
        self.environment = environment
        self.expiresDate = expiresDate
    }
}

/// Verifies a StoreKit-2 signed transaction (JWS, ES256) against the pinned Apple root,
/// then against this app's identity.
///
/// The `x5c` header carries the leaf → intermediate → Apple-Root-CA-G3 chain; the chain
/// must terminate at the pinned root and the leaf's P256 signature must cover
/// `header.payload` before one byte of the payload is believed. Bundle and product
/// checks come *after* the cryptography — they are claims from the payload, and reading
/// them earlier would mean branching on attacker-controlled data.
public struct AppStoreJWSVerifier: Sendable {
    private let expectedBundleId: String
    private let knownProductIds: Set<String>
    private let core: JWSCore

    /// Production initializer: pins the embedded Apple Root CA G3.
    public init(
        expectedBundleId: String,
        knownProductIds: Set<String>,
        validationTime: Date? = nil
    ) {
        self.expectedBundleId = expectedBundleId
        self.knownProductIds = knownProductIds
        self.core = JWSCore(
            rootCertificates: CertificateStore([JWSCore.appleRootCAG3]),
            validationTime: validationTime)
    }

    /// Test initializer: verifies against a supplied root, so unit tests never depend on
    /// Apple's PKI.
    public init(
        expectedBundleId: String,
        knownProductIds: Set<String>,
        pinnedRoots: [Certificate],
        validationTime: Date? = nil
    ) {
        self.expectedBundleId = expectedBundleId
        self.knownProductIds = knownProductIds
        self.core = JWSCore(
            rootCertificates: CertificateStore(pinnedRoots), validationTime: validationTime)
    }

    /// Verifies `jws` and returns its trusted payload.
    public func verify(_ jws: String) async throws(JWSVerificationError) -> VerifiedTransaction {
        let payload = try await core.verify(jws)
        let claims = try JWSCore.decodeJSON(Claims.self, from: payload)

        guard claims.bundleId == expectedBundleId else { throw .wrongBundleId }
        guard knownProductIds.contains(claims.productId) else { throw .unknownProduct }

        return VerifiedTransaction(
            bundleId: claims.bundleId,
            productId: claims.productId,
            transactionId: claims.transactionId,
            originalTransactionId: claims.originalTransactionId,
            // StoreKit epochs are milliseconds.
            purchaseDate: Date(timeIntervalSince1970: Double(claims.purchaseDate) / 1000),
            environment: claims.environment,
            expiresDate: claims.expiresDate.map {
                Date(timeIntervalSince1970: Double($0) / 1000)
            })
    }

    private struct Claims: Decodable {
        let bundleId: String
        let productId: String
        let transactionId: String
        let originalTransactionId: String
        let purchaseDate: Int64
        let environment: String
        let expiresDate: Int64?
    }
}

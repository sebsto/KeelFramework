public import X509

#if canImport(FoundationEssentials)
public import FoundationEssentials
#else
public import Foundation
#endif

/// An App Store Server Notification v2, after its outer JWS verified.
public struct NotificationPayload: Sendable, Equatable {
    /// The raw type string — `REFUND`, `REVOKE`, `DID_RENEW`, `EXPIRED`, … Kept as a
    /// string plus classified accessors rather than a closed enum: Apple adds types, and
    /// a notification this build has not heard of must be acknowledged, not 400'd into
    /// Apple's retry loop.
    public let notificationType: String

    public let subtype: String?
    public let notificationUUID: String

    /// The inner transaction JWS, verified separately by `verifyTransactionInfo`.
    public let signedTransactionInfo: String?

    public let bundleId: String?
    public let environment: String?

    /// The types that take an entitlement away. Everything else is informational to a
    /// backend whose only IAP state is "entitled or not".
    public var revokesEntitlement: Bool {
        notificationType == "REFUND" || notificationType == "REVOKE"
            || notificationType == "EXPIRED"
    }

    public init(
        notificationType: String,
        subtype: String? = nil,
        notificationUUID: String,
        signedTransactionInfo: String? = nil,
        bundleId: String? = nil,
        environment: String? = nil
    ) {
        self.notificationType = notificationType
        self.subtype = subtype
        self.notificationUUID = notificationUUID
        self.signedTransactionInfo = signedTransactionInfo
        self.bundleId = bundleId
        self.environment = environment
    }
}

/// The trusted payload of a verified inner `signedTransactionInfo`.
public struct SignedTransactionInfo: Sendable, Equatable {
    public let transactionId: String
    public let originalTransactionId: String
    public let productId: String
    public let bundleId: String
    public let environment: String
    public let revocationDate: Date?
    public let expiresDate: Date?

    public init(
        transactionId: String,
        originalTransactionId: String,
        productId: String,
        bundleId: String,
        environment: String,
        revocationDate: Date? = nil,
        expiresDate: Date? = nil
    ) {
        self.transactionId = transactionId
        self.originalTransactionId = originalTransactionId
        self.productId = productId
        self.bundleId = bundleId
        self.environment = environment
        self.revocationDate = revocationDate
        self.expiresDate = expiresDate
    }
}

/// Verifies App Store Server Notification v2 payloads: the same x5c-chain-plus-ES256
/// mechanics as transactions, applied twice — once to the outer envelope, once to the
/// inner `signedTransactionInfo`.
///
/// The outer envelope carries no bundleId to pin, so identity checks belong to the
/// handler, against the *inner* transaction — the only part that names a product.
public struct NotificationVerifier: Sendable {
    private let core: JWSCore

    /// Production initializer: pins the embedded Apple Root CA G3.
    public init(validationTime: Date? = nil) {
        self.core = JWSCore(
            rootCertificates: CertificateStore([JWSCore.appleRootCAG3]),
            validationTime: validationTime)
    }

    /// Test initializer: verifies against supplied roots.
    public init(pinnedRoots: [Certificate], validationTime: Date? = nil) {
        self.core = JWSCore(
            rootCertificates: CertificateStore(pinnedRoots), validationTime: validationTime)
    }

    /// Verifies the outer notification JWS (`signedPayload`).
    public func verify(
        _ signedPayload: String
    ) async throws(JWSVerificationError)
        -> NotificationPayload
    {
        let payload = try await core.verify(signedPayload)
        let claims = try JWSCore.decodeJSON(EnvelopeClaims.self, from: payload)
        return NotificationPayload(
            notificationType: claims.notificationType,
            subtype: claims.subtype,
            notificationUUID: claims.notificationUUID,
            signedTransactionInfo: claims.data?.signedTransactionInfo,
            bundleId: claims.data?.bundleId,
            environment: claims.data?.environment)
    }

    /// Verifies the inner `signedTransactionInfo` JWS.
    public func verifyTransactionInfo(
        _ jws: String
    ) async throws(JWSVerificationError)
        -> SignedTransactionInfo
    {
        let payload = try await core.verify(jws)
        let claims = try JWSCore.decodeJSON(TransactionClaims.self, from: payload)
        return SignedTransactionInfo(
            transactionId: claims.transactionId,
            originalTransactionId: claims.originalTransactionId,
            productId: claims.productId,
            bundleId: claims.bundleId,
            environment: claims.environment,
            // StoreKit epochs are milliseconds.
            revocationDate: claims.revocationDate.map {
                Date(timeIntervalSince1970: Double($0) / 1000)
            },
            expiresDate: claims.expiresDate.map {
                Date(timeIntervalSince1970: Double($0) / 1000)
            })
    }

    private struct EnvelopeClaims: Decodable {
        struct Payload: Decodable {
            let signedTransactionInfo: String?
            let bundleId: String?
            let environment: String?
        }

        let notificationType: String
        let subtype: String?
        let notificationUUID: String
        let data: Payload?
    }

    private struct TransactionClaims: Decodable {
        let transactionId: String
        let originalTransactionId: String
        let productId: String
        let bundleId: String
        let environment: String
        let revocationDate: Int64?
        let expiresDate: Int64?
    }
}

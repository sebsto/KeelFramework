public import X509

#if canImport(FoundationEssentials)
public import FoundationEssentials
#else
public import Foundation
#endif

/// An App Store Server Notification v2 type — `REFUND`, `REVOKE`, `DID_RENEW`, `EXPIRED`, …
///
/// A `RawRepresentable` open enum, not a closed one and not a bare `String`. Apple curates
/// this list and adds to it; a closed enum would turn a type this build has not heard of into
/// a decode failure (and Apple into a retry loop), while a plain `String` gives up the compiler
/// for nothing. The pattern is the one `HTTPField.Name` uses: dot-syntax in a `switch`, a typo
/// on a named constant is a compile error, and a type Apple ships next year arrives as a value.
///
/// Only the two types every backend has an opinion about are named here — the framework does
/// not curate Apple's ~15, an app compares against `Self(rawValue:)` for anything else.
public struct AppStoreNotificationType: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let refund = Self(rawValue: "REFUND")
    public static let consumptionRequest = Self(rawValue: "CONSUMPTION_REQUEST")
}

/// An App Store Server Notification v2, after its outer JWS verified.
///
/// The initializer is deliberately **not public**: the only way an adopting app can obtain a
/// value is `try await verifier.verify(rawBody)`, so any function taking a `NotificationPayload`
/// is provably handling data Apple signed. The init is `package`-scoped so `KeelAppStoreTesting`
/// (the same package) can build fixtures, while code in any other package cannot fabricate one.
public struct NotificationPayload: Sendable, Equatable {
    /// The notification type, as an open enum — see `AppStoreNotificationType`. A type this
    /// build has not heard of is still a value, so it is acknowledged, not 400'd into Apple's
    /// retry loop.
    public let notificationType: AppStoreNotificationType

    public let subtype: String?
    public let notificationUUID: String

    /// The inner transaction JWS, verified separately by `verifyTransactionInfo`.
    public let signedTransactionInfo: String?

    public let bundleId: String?
    public let environment: String?

    /// `KeelAppStoreTesting`, which is the same package, reaches this to build fixtures.
    package init(
        notificationType: AppStoreNotificationType,
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
///
/// Same rule as `NotificationPayload`: the initializer is not public, so a value can only come
/// out of `verifier.verifyTransactionInfo(_:)`. `package`-scoped so `KeelAppStoreTesting` builds
/// one for tests.
public struct SignedTransactionInfo: Sendable, Equatable {
    public let transactionId: String
    public let originalTransactionId: String
    public let productId: String
    public let bundleId: String
    public let environment: String
    public let revocationDate: Date?
    public let expiresDate: Date?

    package init(
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
            notificationType: AppStoreNotificationType(rawValue: claims.notificationType),
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

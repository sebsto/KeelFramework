import KeelServer
public import Logging

#if canImport(FoundationEssentials)
public import FoundationEssentials
#else
public import Foundation
#endif

/// The body of `POST /v1/appstore-notification`, as Apple sends it.
public struct NotificationRequest: Decodable, Sendable, Equatable {
    public var signedPayload: String

    public init(signedPayload: String) {
        self.signedPayload = signedPayload
    }
}

/// The acknowledgement Apple expects: any 2xx. The body is for humans reading traces.
public struct NotificationAck: Encodable, Sendable, Equatable {
    public var ok: Bool

    public init(ok: Bool = true) {
        self.ok = ok
    }
}

/// `POST /v1/appstore-notification` — App Store Server Notifications v2.
///
/// The route is public by necessity — Apple's servers hold no credentials of ours — and
/// safe because verification *is* the authentication: an unverifiable payload gets a 401
/// and changes nothing, so an anonymous caller can do nothing here but collect one.
///
/// Only revocations act (`REFUND`, `REVOKE`, `EXPIRED` → the entitlement flips to
/// revoked); everything else is acknowledged and logged. Renewal bookkeeping is already
/// covered by expiry evaluation on read, and acting on types this build does not
/// understand is how a notification handler grows wrong branches.
public struct NotificationHandler: Sendable {
    let verifier: NotificationVerifier
    let store: any EntitlementStore

    /// The bundle this backend serves. Checked on the *inner* transaction — the outer
    /// envelope's copy is unauthenticated context.
    let expectedBundleId: String

    let clock: @Sendable () -> Date
    let logger: Logger

    public init(
        verifier: NotificationVerifier,
        store: any EntitlementStore,
        expectedBundleId: String,
        clock: @escaping @Sendable () -> Date = { Date() },
        logger: Logger = Logger(label: "keel.iap")
    ) {
        self.verifier = verifier
        self.store = store
        self.expectedBundleId = expectedBundleId
        self.clock = clock
        self.logger = logger
    }

    public func handle(_ request: NotificationRequest) async throws -> NotificationAck {
        let notification: NotificationPayload
        do {
            notification = try await verifier.verify(request.signedPayload)
        } catch {
            logger.warning(
                "Rejected an App Store notification", metadata: ["reason": "\(error)"])
            throw KeelError.badRequest(field: "signedPayload", reason: "not a verifiable payload")
        }

        logger.info(
            "App Store notification",
            metadata: [
                "type": .string(notification.notificationType),
                "subtype": .string(notification.subtype ?? "-"),
                "uuid": .string(notification.notificationUUID),
            ])

        guard notification.revokesEntitlement else {
            return NotificationAck()
        }
        guard let inner = notification.signedTransactionInfo else {
            // A revocation with no transaction cannot name what to revoke. Acknowledge —
            // retrying will not grow it a transaction — and log loudly.
            logger.error("Revocation notification without signedTransactionInfo")
            return NotificationAck()
        }

        let transaction = try await verifier.verifyTransactionInfo(inner)
        guard transaction.bundleId == expectedBundleId else {
            // Verified, but for some other app — a misconfigured App Store Connect
            // endpoint, most likely. Not ours to act on.
            logger.error(
                "Notification for a different bundle",
                metadata: ["bundleId": .string(transaction.bundleId)])
            return NotificationAck()
        }

        guard
            let owner = try await store.owner(
                originalTransactionId: transaction.originalTransactionId)
        else {
            // No purchase ever recorded this lineage — a refund for a purchase made
            // before the backend existed, or one that never reached `/v1/purchase`.
            // Acknowledged: Apple retrying cannot make the purchase appear.
            logger.warning(
                "Revocation for an unknown transaction lineage",
                metadata: ["originalTransactionId": .string(transaction.originalTransactionId)])
            return NotificationAck()
        }

        let existing = try await store.entitlements(userId: owner.userId)
        guard var entitlement = existing.first(where: { $0.productId == owner.productId })
        else {
            logger.error(
                "TXN# pointer with no matching entitlement",
                metadata: ["userId": .string(owner.userId)])
            return NotificationAck()
        }

        let now = clock()
        entitlement.state = .revoked
        entitlement.revocationDate = transaction.revocationDate ?? now
        entitlement.updatedAt = now
        try await store.save(entitlement, userId: owner.userId)

        logger.info(
            "Revoked entitlement",
            metadata: [
                "product": .string(owner.productId),
                "type": .string(notification.notificationType),
            ])
        return NotificationAck()
    }
}

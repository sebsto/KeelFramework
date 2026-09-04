public import KeelAppStore

#if canImport(FoundationEssentials)
public import FoundationEssentials
#else
public import Foundation
#endif

/// Fixture factory for `KeelAppStore`'s verified-payload types.
///
/// `NotificationPayload` and `SignedTransactionInfo` have no public initializer on purpose: the
/// only way an adopting app obtains one is through the verifier, so any code holding one is
/// provably holding data Apple signed. That makes them awkward to build in a test — which is
/// what this module is for. It is the same package as `KeelAppStore`, so it can reach their
/// `package`-scoped inits; a test in another package cannot, and neither can an app.
public enum KeelAppStoreFixtures {
    /// Build a `NotificationPayload` as the verifier would have produced it.
    public static func notificationPayload(
        notificationType: AppStoreNotificationType,
        subtype: String? = nil,
        notificationUUID: String = "00000000-0000-4000-8000-000000000000",
        signedTransactionInfo: String? = nil,
        bundleId: String? = nil,
        environment: String? = nil
    ) -> NotificationPayload {
        NotificationPayload(
            notificationType: notificationType,
            subtype: subtype,
            notificationUUID: notificationUUID,
            signedTransactionInfo: signedTransactionInfo,
            bundleId: bundleId,
            environment: environment)
    }

    /// Build a `SignedTransactionInfo` as the verifier would have produced it.
    public static func signedTransactionInfo(
        transactionId: String = "2000000000000001",
        originalTransactionId: String = "2000000000000000",
        productId: String = "unlock_pro",
        bundleId: String = "com.example.app",
        environment: String = "Production",
        revocationDate: Date? = nil,
        expiresDate: Date? = nil
    ) -> SignedTransactionInfo {
        SignedTransactionInfo(
            transactionId: transactionId,
            originalTransactionId: originalTransactionId,
            productId: productId,
            bundleId: bundleId,
            environment: environment,
            revocationDate: revocationDate,
            expiresDate: expiresDate)
    }
}

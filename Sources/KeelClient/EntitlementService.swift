public import Foundation
public import KeelCore
public import Observation
import StoreKit

/// One verified, currently-relevant purchase, as `EntitlementService` reasons about it.
///
/// A plain value extracted from StoreKit's `Transaction` so the state computation is a
/// pure function and the service is testable without StoreKit — which cannot be faked in
/// a unit test host.
public struct CurrentPurchase: Sendable, Equatable {
    public var productID: String
    public var expirationDate: Date?
    public var revocationDate: Date?

    /// `Transaction.jwsRepresentation`, for reporting to a Keel backend with IAP mounted.
    public var jwsRepresentation: String

    public init(
        productID: String,
        expirationDate: Date? = nil,
        revocationDate: Date? = nil,
        jwsRepresentation: String = ""
    ) {
        self.productID = productID
        self.expirationDate = expirationDate
        self.revocationDate = revocationDate
        self.jwsRepresentation = jwsRepresentation
    }
}

/// The seam between `EntitlementService` and StoreKit. The production conformance reads
/// `Transaction.currentEntitlements`; tests hand back arrays.
public protocol EntitlementProvider: Sendable {
    /// The verified entitlements StoreKit holds right now. Works offline — StoreKit
    /// caches — which is what makes the service offline-tolerant for free.
    func currentEntitlements() async -> [CurrentPurchase]

    /// Fires whenever a transaction changes: purchase, renewal, revocation, Ask to Buy.
    func updates() -> AsyncStream<Void>
}

/// The production provider: StoreKit 2, verified transactions only.
public struct StoreKitEntitlementProvider: EntitlementProvider {
    public init() {}

    public func currentEntitlements() async -> [CurrentPurchase] {
        var purchases: [CurrentPurchase] = []
        for await result in Transaction.currentEntitlements {
            // Unverified transactions are dropped, not downgraded: StoreKit already did
            // the cryptography, and a transaction it cannot vouch for entitles nothing.
            guard case .verified(let transaction) = result else { continue }
            purchases.append(
                CurrentPurchase(
                    productID: transaction.productID,
                    expirationDate: transaction.expirationDate,
                    revocationDate: transaction.revocationDate,
                    jwsRepresentation: result.jwsRepresentation))
        }
        return purchases
    }

    public func updates() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let task = Task {
                for await _ in Transaction.updates {
                    continuation.yield()
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// StoreKit 2 → `LicenseState`, observable by SwiftUI.
///
/// The app declares which products mean *paid* and which mean *trial*; the service folds
/// StoreKit's current entitlements into the single enum the rest of Keel speaks — the
/// same value the telemetry ping carries and the cohort charts split by.
///
/// ```swift
/// let entitlements = EntitlementService(paidProducts: ["unlock_pro"])
/// // in the root view:
/// .task { await entitlements.start() }
/// ```
@Observable
@MainActor
public final class EntitlementService {
    /// The current state. `.free` until the first refresh completes — the conservative
    /// default, and StoreKit answers from its local cache fast enough that a paid user
    /// does not see a flash of locked UI in practice.
    public private(set) var licenseState: LicenseState = .free

    /// The newest relevant JWS, for apps that forward a transaction to their own backend
    /// (Keel verifies App Store paperwork via `KeelAppStore` but no longer offers a
    /// purchase-reporting route — what a purchase grants is the app's own concern). Nil for
    /// free users.
    public private(set) var latestTransactionJWS: String?

    private let paidProducts: Set<String>
    private let trialProducts: Set<String>
    private let provider: any EntitlementProvider
    private let now: @Sendable () -> Date

    public init(
        paidProducts: Set<String>,
        trialProducts: Set<String> = [],
        provider: any EntitlementProvider = StoreKitEntitlementProvider(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.paidProducts = paidProducts
        self.trialProducts = trialProducts
        self.provider = provider
        self.now = now
    }

    /// Refresh once, then follow StoreKit's updates until cancelled. The intended call:
    /// one `.task` at the root, alive for the scene's lifetime.
    public func start() async {
        await refresh()
        for await _ in provider.updates() {
            await refresh()
        }
    }

    /// Recompute the state from StoreKit's current entitlements.
    public func refresh() async {
        let purchases = await provider.currentEntitlements()
        let reference = now()
        licenseState = Self.state(
            for: purchases,
            paidProducts: paidProducts,
            trialProducts: trialProducts,
            now: reference)
        latestTransactionJWS =
            Self.relevantPurchase(
                in: purchases, paidProducts: paidProducts, trialProducts: trialProducts,
                now: reference)?.jwsRepresentation
    }

    /// The pure fold: paid beats trial beats free, revoked and expired entitle nothing.
    nonisolated static func state(
        for purchases: [CurrentPurchase],
        paidProducts: Set<String>,
        trialProducts: Set<String>,
        now: Date
    ) -> LicenseState {
        let active = purchases.filter { $0.entitles(at: now) }
        if active.contains(where: { paidProducts.contains($0.productID) }) {
            return .paid
        }
        if active.contains(where: { trialProducts.contains($0.productID) }) {
            return .trial
        }
        return .free
    }

    nonisolated static func relevantPurchase(
        in purchases: [CurrentPurchase],
        paidProducts: Set<String>,
        trialProducts: Set<String>,
        now: Date
    ) -> CurrentPurchase? {
        let declared = paidProducts.union(trialProducts)
        return
            purchases
            .filter { $0.entitles(at: now) && declared.contains($0.productID) }
            .max { ($0.expirationDate ?? .distantFuture) < ($1.expirationDate ?? .distantFuture) }
    }
}

extension CurrentPurchase {
    /// Active right now: not revoked, not past expiry. No expiry means a non-consumable,
    /// which is permanent.
    func entitles(at now: Date) -> Bool {
        guard revocationDate == nil else { return false }
        guard let expirationDate else { return true }
        return now < expirationDate
    }
}

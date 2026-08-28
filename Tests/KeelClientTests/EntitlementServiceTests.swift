import Foundation
import KeelCore
import Testing

@testable import KeelClient

/// The pure fold from StoreKit's entitlements to `LicenseState` — the part worth testing,
/// since StoreKit itself cannot be faked in a unit test host.
@Suite("Entitlement service")
struct EntitlementServiceTests {

    static let now = Date(timeIntervalSince1970: 1_700_000_000)

    private static func state(
        _ purchases: [CurrentPurchase],
        paid: Set<String> = ["unlock_pro", "sub_monthly"],
        trial: Set<String> = ["trial_30"]
    ) -> LicenseState {
        EntitlementService.state(
            for: purchases, paidProducts: paid, trialProducts: trial, now: now)
    }

    @Test("No purchases means free")
    func empty() {
        #expect(Self.state([]) == .free)
    }

    @Test("A non-consumable with no expiry is permanently paid")
    func nonConsumable() {
        #expect(Self.state([CurrentPurchase(productID: "unlock_pro")]) == .paid)
    }

    @Test("An unexpired subscription is paid; an expired one is not")
    func subscriptionExpiry() {
        let active = CurrentPurchase(
            productID: "sub_monthly", expirationDate: Self.now.addingTimeInterval(3_600))
        #expect(Self.state([active]) == .paid)

        let expired = CurrentPurchase(
            productID: "sub_monthly", expirationDate: Self.now.addingTimeInterval(-3_600))
        #expect(Self.state([expired]) == .free)
    }

    @Test("A revoked purchase entitles nothing, whatever its dates say")
    func revoked() {
        let refunded = CurrentPurchase(
            productID: "unlock_pro", revocationDate: Self.now.addingTimeInterval(-60))
        #expect(Self.state([refunded]) == .free)
    }

    @Test("Trial products read as trial, and paid beats trial")
    func trialPrecedence() {
        let trial = CurrentPurchase(
            productID: "trial_30", expirationDate: Self.now.addingTimeInterval(86_400))
        #expect(Self.state([trial]) == .trial)

        // Someone converting mid-trial is a paid user, not a trial one — the cohort
        // charts split on exactly this.
        let both = [trial, CurrentPurchase(productID: "unlock_pro")]
        #expect(Self.state(both) == .paid)
    }

    @Test("A product the app never declared entitles nothing")
    func undeclaredProduct() {
        #expect(Self.state([CurrentPurchase(productID: "mystery")]) == .free)
    }

    @Test("The service folds the provider's answer and follows updates")
    @MainActor
    func serviceFollowsProvider() async {
        let service = EntitlementService(
            paidProducts: ["unlock_pro"],
            provider: FixedProvider(purchases: [
                CurrentPurchase(productID: "unlock_pro", jwsRepresentation: "jws-1")
            ]),
            now: { Self.now })

        #expect(service.licenseState == .free)
        await service.refresh()
        #expect(service.licenseState == .paid)
        #expect(service.latestTransactionJWS == "jws-1")
    }
}

private struct FixedProvider: EntitlementProvider {
    let purchases: [CurrentPurchase]

    func currentEntitlements() async -> [CurrentPurchase] {
        purchases
    }

    func updates() -> AsyncStream<Void> {
        AsyncStream { $0.finish() }
    }
}

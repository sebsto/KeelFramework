import Foundation
import KeelServer
import Logging
import Testing

@testable import KeelIAP

/// An in-memory `EntitlementStore` — an actor because these tests have no need for the
/// synchronous-assertion trick the counter fakes use.
actor InMemoryEntitlementStore: EntitlementStore {
    private var byUser: [String: [String: Entitlement]] = [:]
    private var owners: [String: TransactionOwner] = [:]

    func entitlements(userId: String) async throws -> [Entitlement] {
        Array((byUser[userId] ?? [:]).values)
    }

    func save(_ entitlement: Entitlement, userId: String) async throws {
        byUser[userId, default: [:]][entitlement.productId] = entitlement
    }

    func owner(originalTransactionId: String) async throws -> TransactionOwner? {
        owners[originalTransactionId]
    }

    func saveOwner(_ owner: TransactionOwner, originalTransactionId: String) async throws {
        owners[originalTransactionId] = owner
    }
}

@Suite("Purchase, entitlement and notification handlers")
struct EntitlementHandlerTests {

    static let now = Date(timeIntervalSince1970: 1_700_003_600)

    private struct Harness {
        let store = InMemoryEntitlementStore()
        var purchase: PurchaseHandler {
            PurchaseHandler(
                verifier: AppStoreJWSVerifier(
                    expectedBundleId: "com.example.app",
                    knownProductIds: ["unlock_pro", "sub_monthly"],
                    pinnedRoots: [TestPKI.root],
                    validationTime: TestPKI.start),
                store: store,
                clock: { EntitlementHandlerTests.now })
        }

        var entitlement: EntitlementHandler {
            EntitlementHandler(store: store, clock: { EntitlementHandlerTests.now })
        }

        var notification: NotificationHandler {
            NotificationHandler(
                verifier: NotificationVerifier(
                    pinnedRoots: [TestPKI.root], validationTime: TestPKI.start),
                store: store,
                expectedBundleId: "com.example.app",
                clock: { EntitlementHandlerTests.now })
        }
    }

    // MARK: - Purchase

    @Test("A verified purchase grants the entitlement and records the reverse pointer")
    func purchaseGrants() async throws {
        let harness = Harness()
        let response = try await harness.purchase.handle(
            PurchaseRequest(userId: "user-1", jws: TestPKI.transactionJWS()))

        #expect(response.entitlements.count == 1)
        let wire = try #require(response.entitlements.first)
        #expect(wire.productId == "unlock_pro")
        #expect(wire.isEntitled)
        #expect(wire.state == "active")

        // The reverse pointer is what a refund notification will need.
        let owner = try await harness.store.owner(
            originalTransactionId: "2000000000000000")
        #expect(owner == TransactionOwner(userId: "user-1", productId: "unlock_pro"))
    }

    @Test("Replaying the same transaction is idempotent — restore purchases just works")
    func purchaseIsIdempotent() async throws {
        let harness = Harness()
        let jws = TestPKI.transactionJWS()
        _ = try await harness.purchase.handle(PurchaseRequest(userId: "user-1", jws: jws))
        let second = try await harness.purchase.handle(
            PurchaseRequest(userId: "user-1", jws: jws))
        #expect(second.entitlements.count == 1)
    }

    @Test("An unverifiable JWS is one undifferentiated 400")
    func purchaseRejectsBadJWS() async throws {
        let harness = Harness()
        // Three different failure modes, one externally visible answer — a forger gets
        // no progress meter.
        for jws in [
            TestPKI.transactionJWS(tamper: true),
            TestPKI.transactionJWS(bundleId: "com.other.app"),
            "garbage",
        ] {
            await #expect(throws: KeelError.self) {
                _ = try await harness.purchase.handle(
                    PurchaseRequest(userId: "user-1", jws: jws))
            }
        }
        #expect(try await harness.store.entitlements(userId: "user-1").isEmpty)
    }

    @Test("A userId that cannot be a key is rejected before verification")
    func purchaseValidatesUserId() async {
        let harness = Harness()
        for userId in ["", String(repeating: "u", count: 129), "user 1", "usér"] {
            await #expect(throws: KeelError.self) {
                _ = try await harness.purchase.handle(
                    PurchaseRequest(userId: userId, jws: TestPKI.transactionJWS()))
            }
        }
    }

    // MARK: - Entitlement

    @Test("A user who never bought anything gets an empty list, not an error")
    func unknownUserIsEmpty() async throws {
        let response = try await Harness().entitlement.handle(userId: "nobody")
        #expect(response.entitlements.isEmpty)
        #expect(response.generatedAt == Self.now)
    }

    @Test("An expired subscription reads as not entitled without any notification")
    func expiryIsEvaluatedOnRead() async throws {
        let harness = Harness()
        _ = try await harness.purchase.handle(
            PurchaseRequest(
                userId: "user-1",
                jws: TestPKI.transactionJWS(
                    productId: "sub_monthly",
                    // Expired an hour before `now`.
                    expiresDateMillis: Int64(Self.now.timeIntervalSince1970 - 3_600) * 1000)))

        let response = try await harness.entitlement.handle(userId: "user-1")
        let wire = try #require(response.entitlements.first)
        // Still `active` in state — Apple has not said otherwise — but not entitled:
        // expiry is a fact of the clock, not of the notification pipeline.
        #expect(wire.state == "active")
        #expect(!wire.isEntitled)
    }

    // MARK: - Notifications

    @Test("A REFUND revokes the entitlement through the reverse pointer")
    func refundRevokes() async throws {
        let harness = Harness()
        _ = try await harness.purchase.handle(
            PurchaseRequest(userId: "user-1", jws: TestPKI.transactionJWS()))

        let ack = try await harness.notification.handle(
            NotificationRequest(
                signedPayload: TestPKI.notificationJWS(
                    type: "REFUND", revocationDateMillis: 1_700_002_000_000)))
        #expect(ack == NotificationAck())

        let response = try await harness.entitlement.handle(userId: "user-1")
        let wire = try #require(response.entitlements.first)
        #expect(wire.state == "revoked")
        #expect(!wire.isEntitled)
    }

    @Test("An informational notification is acknowledged and changes nothing")
    func informationalTypesAreAcknowledged() async throws {
        let harness = Harness()
        _ = try await harness.purchase.handle(
            PurchaseRequest(userId: "user-1", jws: TestPKI.transactionJWS()))

        for type in ["DID_RENEW", "SUBSCRIBED", "TEST", "SOME_FUTURE_TYPE"] {
            _ = try await harness.notification.handle(
                NotificationRequest(signedPayload: TestPKI.notificationJWS(type: type)))
        }

        let response = try await harness.entitlement.handle(userId: "user-1")
        #expect(response.entitlements.first?.isEntitled == true)
    }

    @Test("A refund for a lineage no purchase recorded is acknowledged, not retried")
    func unknownLineageIsAcknowledged() async throws {
        let harness = Harness()
        // A 4xx would put Apple into a retry loop that can never succeed.
        let ack = try await harness.notification.handle(
            NotificationRequest(
                signedPayload: TestPKI.notificationJWS(
                    type: "REFUND", originalTransactionId: "555")))
        #expect(ack == NotificationAck())
    }

    @Test("A refund for a different bundle is acknowledged and acts on nothing")
    func wrongBundleIsIgnored() async throws {
        let harness = Harness()
        _ = try await harness.purchase.handle(
            PurchaseRequest(userId: "user-1", jws: TestPKI.transactionJWS()))

        _ = try await harness.notification.handle(
            NotificationRequest(
                signedPayload: TestPKI.notificationJWS(
                    type: "REFUND", bundleId: "com.other.app")))

        let response = try await harness.entitlement.handle(userId: "user-1")
        #expect(response.entitlements.first?.isEntitled == true)
    }

    @Test("An unverifiable notification is a 400 — verification is the authentication")
    func unverifiableNotificationRejected() async {
        let harness = Harness()
        await #expect(throws: KeelError.self) {
            _ = try await harness.notification.handle(
                NotificationRequest(signedPayload: "garbage"))
        }
    }
}

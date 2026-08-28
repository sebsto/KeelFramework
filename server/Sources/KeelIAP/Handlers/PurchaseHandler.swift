import KeelServer
public import Logging

#if canImport(FoundationEssentials)
public import FoundationEssentials
#else
public import Foundation
#endif

/// `POST /v1/purchase` — verify StoreKit's proof, grant the entitlement.
///
/// The JWS *is* the authorization: a caller who presents a signed transaction for this
/// bundle and a known product gets the entitlement recorded for the `userId` they name.
/// Binding it to a userId Apple never saw is the honest limit of server-side StoreKit —
/// Apple signs the purchase, the app asserts whose it is — and it is why the route sits
/// behind the API's auth mode rather than being public.
///
/// Idempotent by construction: re-presenting the same transaction overwrites the same
/// `ENT#` item with the same values, so a client that retries after a timeout cannot
/// double-grant, and a restore-purchases flow just replays the newest JWS.
public struct PurchaseHandler: Sendable {
    let verifier: AppStoreJWSVerifier
    let store: any EntitlementStore
    let clock: @Sendable () -> Date
    let logger: Logger

    public init(
        verifier: AppStoreJWSVerifier,
        store: any EntitlementStore,
        clock: @escaping @Sendable () -> Date = { Date() },
        logger: Logger = Logger(label: "keel.iap")
    ) {
        self.verifier = verifier
        self.store = store
        self.clock = clock
        self.logger = logger
    }

    public func handle(_ request: PurchaseRequest) async throws -> EntitlementResponse {
        let userId = try Self.validatedUserId(request.userId)

        let transaction: VerifiedTransaction
        do {
            transaction = try await verifier.verify(request.jws)
        } catch {
            // The specific failure goes to the log; the caller gets one undifferentiated
            // rejection. Distinguishing "bad signature" from "unknown product" outward
            // would hand a forger a progress meter.
            logger.warning(
                "Rejected a purchase JWS", metadata: ["reason": "\(error)"])
            throw KeelError.badRequest(field: "jws", reason: "not a verifiable transaction")
        }

        let now = clock()
        let entitlement = Entitlement(
            productId: transaction.productId,
            state: .active,
            purchaseDate: transaction.purchaseDate,
            expiresDate: transaction.expiresDate,
            originalTransactionId: transaction.originalTransactionId,
            environment: transaction.environment,
            updatedAt: now)

        // The reverse pointer first: if the second write fails, a `TXN#` item without an
        // entitlement revokes nothing and grants nothing, while the opposite order could
        // leave a granted entitlement no notification can ever find.
        try await store.saveOwner(
            TransactionOwner(userId: userId, productId: transaction.productId),
            originalTransactionId: transaction.originalTransactionId)
        try await store.save(entitlement, userId: userId)

        logger.info(
            "Granted entitlement",
            metadata: [
                "product": .string(transaction.productId),
                "environment": .string(transaction.environment),
            ])
        return EntitlementResponse(
            entitlements: try await store.entitlements(userId: userId), at: now)
    }

    /// Bounded and printable, because it becomes a partition key — same reasoning as the
    /// ping strings, same rejection-over-truncation rule.
    static func validatedUserId(_ userId: String) throws(KeelError) -> String {
        guard !userId.isEmpty else {
            throw .badRequest(field: "userId", reason: "must not be empty")
        }
        guard userId.utf8.count <= EntitlementSchema.userIdLimit else {
            throw .badRequest(
                field: "userId",
                reason: "must be at most \(EntitlementSchema.userIdLimit) bytes")
        }
        guard userId.utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7F }) else {
            throw .badRequest(field: "userId", reason: "must be printable ASCII without spaces")
        }
        return userId
    }
}

/// `GET /v1/entitlement` — what the server holds for one user.
public struct EntitlementHandler: Sendable {
    let store: any EntitlementStore
    let clock: @Sendable () -> Date

    public init(
        store: any EntitlementStore,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.clock = clock
    }

    public func handle(userId: String) async throws -> EntitlementResponse {
        let validated = try PurchaseHandler.validatedUserId(userId)
        // An unknown user is an empty list, not a 404: "never bought anything" is a
        // normal answer, and the client treats both identically.
        return EntitlementResponse(
            entitlements: try await store.entitlements(userId: validated), at: clock())
    }
}

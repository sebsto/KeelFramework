#if canImport(FoundationEssentials)
public import FoundationEssentials
#else
public import Foundation
#endif

/// One granted product for one user — the record behind "has this person paid".
///
/// Keyed by the app's own opaque `userId` (a Sign-in-with-Apple `sub`, an account id —
/// whatever the app already has). **This is the one Keel table item keyed by a person**,
/// and it is deliberately outside the telemetry design: entitlements exist only for apps
/// that opt into server-side IAP, live under their own key prefix, and are never joined
/// with any `AGG#` counter (`docs/ARCHITECTURE.md` §9 point 4 still holds — the ping
/// handler never reads or writes these).
public struct Entitlement: Codable, Sendable, Equatable {
    public var productId: String

    public enum State: String, Codable, Sendable {
        case active
        case revoked
    }

    public var state: State
    public var purchaseDate: Date

    /// For auto-renewables. An active entitlement past this date is *expired in fact* —
    /// `isEntitled(at:)` says so — without waiting for Apple's `EXPIRED` notification.
    public var expiresDate: Date?

    /// Set by a refund or revocation notification. Kept, not deleted: "was refunded" is
    /// the fact a support conversation needs.
    public var revocationDate: Date?

    /// Ties the entitlement to the App Store transaction lineage, and is what a server
    /// notification carries — the reverse lookup key.
    public var originalTransactionId: String

    /// `"Sandbox"` or `"Production"`. Stored so a sandbox purchase can never be mistaken
    /// for revenue: the handler grants it (TestFlight must work) but marks it.
    public var environment: String

    public var updatedAt: Date

    public init(
        productId: String,
        state: State,
        purchaseDate: Date,
        expiresDate: Date? = nil,
        revocationDate: Date? = nil,
        originalTransactionId: String,
        environment: String,
        updatedAt: Date
    ) {
        self.productId = productId
        self.state = state
        self.purchaseDate = purchaseDate
        self.expiresDate = expiresDate
        self.revocationDate = revocationDate
        self.originalTransactionId = originalTransactionId
        self.environment = environment
        self.updatedAt = updatedAt
    }

    /// Whether this entitlement grants access at `now`: active, and not past expiry.
    public func isEntitled(at now: Date) -> Bool {
        guard state == .active else { return false }
        guard let expiresDate else { return true }
        return now < expiresDate
    }
}

/// The keys the entitlement items live under — the IAP half of the single table.
///
/// ```
/// ENT#<userId>                 │ <productId>  │ entitlement JSON   (no ttl)
/// TXN#<originalTransactionId>  │ owner        │ userId, productId  (no ttl)
/// ```
///
/// The `TXN#` item is the reverse pointer: a server notification names a transaction, not
/// a user, so revocation needs `originalTransactionId → (userId, productId)`. Written at
/// purchase time, one item per lineage — which keeps the read path Query-only, no GSI,
/// same as the counters (`docs/ARCHITECTURE.md` §4).
public enum EntitlementSchema {
    public static func userPartitionKey(userId: String) -> String {
        "ENT#\(userId)"
    }

    public static func transactionPartitionKey(originalTransactionId: String) -> String {
        "TXN#\(originalTransactionId)"
    }

    public static let transactionSortKey = "owner"

    /// Bounds on the caller-supplied `userId`, which becomes part of a partition key.
    /// Same reasoning as the ping strings: unbounded input means unbounded keys.
    public static let userIdLimit = 128
}

/// Who owns a transaction lineage — the payload of a `TXN#` item.
public struct TransactionOwner: Codable, Sendable, Equatable {
    public var userId: String
    public var productId: String

    public init(userId: String, productId: String) {
        self.userId = userId
        self.productId = productId
    }
}

/// The entitlement items, as the handlers see them. Same design as `CounterStore`: the
/// operations the schema supports and nothing else.
public protocol EntitlementStore: Sendable {
    /// Every entitlement of one user — a Query on `ENT#<userId>`, bounded by the number
    /// of products the app sells.
    func entitlements(userId: String) async throws -> [Entitlement]

    /// Upsert one entitlement (`ENT#<userId>` / `<productId>`).
    func save(_ entitlement: Entitlement, userId: String) async throws

    /// The owner of a transaction lineage, or nil when no purchase recorded it.
    func owner(originalTransactionId: String) async throws -> TransactionOwner?

    /// Record the reverse pointer at purchase time.
    func saveOwner(_ owner: TransactionOwner, originalTransactionId: String) async throws
}

import KeelServer

#if canImport(FoundationEssentials)
public import FoundationEssentials
#else
public import Foundation
#endif

/// The body of `POST /v1/purchase`: who is buying, and StoreKit's signed proof.
public struct PurchaseRequest: Decodable, Sendable, Equatable {
    /// The app's own opaque, stable user identifier. Never invented by Keel — an app
    /// without user identity has no business mounting the IAP routes.
    public var userId: String

    /// `Transaction.jwsRepresentation`, verbatim from StoreKit 2.
    public var jws: String

    public init(userId: String, jws: String) {
        self.userId = userId
        self.jws = jws
    }
}

/// The response to `POST /v1/purchase` and `GET /v1/entitlement`: everything the server
/// holds for this user, current state included — the client replaces, never merges.
public struct EntitlementResponse: Encodable, Sendable, Equatable {
    public struct WireEntitlement: Encodable, Sendable, Equatable {
        public var productId: String
        public var state: String

        /// The one field a client should branch on: active *and* unexpired, evaluated
        /// server-side at `generatedAt` so the client compares no dates.
        public var isEntitled: Bool

        public var purchaseDate: Date
        public var expiresDate: Date?
        public var environment: String

        public init(_ entitlement: Entitlement, at now: Date) {
            self.productId = entitlement.productId
            self.state = entitlement.state.rawValue
            self.isEntitled = entitlement.isEntitled(at: now)
            self.purchaseDate = entitlement.purchaseDate
            self.expiresDate = entitlement.expiresDate
            self.environment = entitlement.environment
        }

        enum CodingKeys: String, CodingKey {
            case productId, state, isEntitled, purchaseDate, expiresDate, environment
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(productId, forKey: .productId)
            try container.encode(state, forKey: .state)
            try container.encode(isEntitled, forKey: .isEntitled)
            try container.encodeISO8601(purchaseDate, forKey: .purchaseDate)
            try container.encodeISO8601IfPresent(expiresDate, forKey: .expiresDate)
            try container.encode(environment, forKey: .environment)
        }
    }

    public var entitlements: [WireEntitlement]
    public var generatedAt: Date

    public init(entitlements: [Entitlement], at now: Date) {
        self.entitlements =
            entitlements
            .sorted { $0.productId < $1.productId }
            .map { WireEntitlement($0, at: now) }
        self.generatedAt = now
    }

    enum CodingKeys: String, CodingKey {
        case entitlements, generatedAt
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(entitlements, forKey: .entitlements)
        try container.encodeISO8601(generatedAt, forKey: .generatedAt)
    }
}

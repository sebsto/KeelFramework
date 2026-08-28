#if canImport(FoundationEssentials)
public import FoundationEssentials
#else
public import Foundation
#endif

/// The body of `POST /v1/purchase`. `Encodable` only — the client sends it; the server's
/// mirror decodes it, pinned together by usage rather than fixtures (the IAP wire shapes
/// are small and optional).
public struct PurchaseRequest: Encodable, Sendable, Equatable {
    /// The app's own opaque, stable user identifier — a SIWA `sub`, an account id.
    public var userId: String

    /// `Transaction.jwsRepresentation`, verbatim.
    public var jws: String

    public init(userId: String, jws: String) {
        self.userId = userId
        self.jws = jws
    }
}

/// The response to `POST /v1/purchase` and `GET /v1/entitlement`: everything the server
/// holds for this user. Replace local state with it wholesale, never merge.
public struct EntitlementResponse: Decodable, Sendable, Equatable {
    public struct WireEntitlement: Decodable, Sendable, Equatable {
        public var productId: String
        public var state: String

        /// The one field to branch on: active *and* unexpired, evaluated server-side so
        /// the client compares no dates.
        public var isEntitled: Bool

        public var purchaseDate: Date
        public var expiresDate: Date?
        public var environment: String

        enum CodingKeys: String, CodingKey {
            case productId, state, isEntitled, purchaseDate, expiresDate, environment
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            productId = try container.decode(String.self, forKey: .productId)
            state = try container.decode(String.self, forKey: .state)
            isEntitled = try container.decode(Bool.self, forKey: .isEntitled)
            purchaseDate = try container.decodeISO8601(forKey: .purchaseDate)
            expiresDate = try container.decodeISO8601IfPresent(forKey: .expiresDate)
            environment = try container.decode(String.self, forKey: .environment)
        }
    }

    public var entitlements: [WireEntitlement]
    public var generatedAt: Date

    enum CodingKeys: String, CodingKey {
        case entitlements, generatedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entitlements = try container.decode([WireEntitlement].self, forKey: .entitlements)
        generatedAt = try container.decodeISO8601(forKey: .generatedAt)
    }
}

/// The body of `POST /v1/ping`, as the server reads it.
///
/// The mirror of `KeelCore.PingRequest`, which is `Encodable`; this one is `Decodable`. Neither
/// side needs both directions, and declaring only the half that is used means a field added to
/// one copy and forgotten in the other fails a fixture test instead of silently round-tripping.
///
/// Nothing here identifies anyone, and that is a property of the *type*, not of the handler: an
/// identifier cannot be logged if it was never a field. The five booleans are the client's own
/// deduplication decision, which the server takes at face value — it has no way to check them
/// and no wish to acquire one (`docs/adr/0004-client-side-dedup-no-identifier.md`).
///
/// A client that lies inflates a counter. That is the whole attack, it is rate-limited by API
/// Gateway, and the alternative costs an identifier.
public struct PingRequest: Decodable, Sendable, Equatable {
    public var firstPingEver: Bool
    public var firstToday: Bool
    public var firstThisMonth: Bool
    public var firstThisVersion: Bool
    public var firstPaidLaunch: Bool

    /// Free text from an untrusted client, and a sort key. `Limits.versionLength` bounds it.
    public var appVersion: String

    /// Same: free text, and a sort key.
    public var osVersion: String

    /// A closed enum, so an unknown value fails decoding and the handler answers 400 rather
    /// than creating an `AGG#PLAT#…` partition nothing will ever read.
    public var platform: Platform

    public var licenseState: LicenseState

    /// Pre-bucketed app-specific values. Absent and empty are the same thing.
    ///
    /// Names *and* values are checked against the config's allowlist before anything is
    /// written; this type only carries them. Unvalidated, a single client could mint unbounded
    /// partitions in the table by sending a random key per request.
    public var dimensions: [String: String]

    public init(
        firstPingEver: Bool,
        firstToday: Bool,
        firstThisMonth: Bool,
        firstThisVersion: Bool,
        firstPaidLaunch: Bool,
        appVersion: String,
        osVersion: String,
        platform: Platform,
        licenseState: LicenseState,
        dimensions: [String: String] = [:]
    ) {
        self.firstPingEver = firstPingEver
        self.firstToday = firstToday
        self.firstThisMonth = firstThisMonth
        self.firstThisVersion = firstThisVersion
        self.firstPaidLaunch = firstPaidLaunch
        self.appVersion = appVersion
        self.osVersion = osVersion
        self.platform = platform
        self.licenseState = licenseState
        self.dimensions = dimensions
    }

    enum CodingKeys: String, CodingKey {
        case firstPingEver, firstToday, firstThisMonth, firstThisVersion, firstPaidLaunch
        case appVersion, osVersion, platform, licenseState, dimensions
    }

    /// The booleans default to `false` and `dimensions` to empty, so a minimal body from a
    /// hand-written client or a retrofitted older app still decodes. `appVersion`, `osVersion`,
    /// `platform` and `licenseState` are required — without them a ping has no counter to move.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        firstPingEver = try container.decodeIfPresent(Bool.self, forKey: .firstPingEver) ?? false
        firstToday = try container.decodeIfPresent(Bool.self, forKey: .firstToday) ?? false
        firstThisMonth = try container.decodeIfPresent(Bool.self, forKey: .firstThisMonth) ?? false
        firstThisVersion =
            try container.decodeIfPresent(Bool.self, forKey: .firstThisVersion) ?? false
        firstPaidLaunch =
            try container.decodeIfPresent(Bool.self, forKey: .firstPaidLaunch) ?? false
        appVersion = try container.decode(String.self, forKey: .appVersion)
        osVersion = try container.decode(String.self, forKey: .osVersion)
        platform = try container.decode(Platform.self, forKey: .platform)
        licenseState = try container.decode(LicenseState.self, forKey: .licenseState)
        dimensions =
            try container.decodeIfPresent([String: String].self, forKey: .dimensions) ?? [:]
    }

    /// True when no counter would move — a body the client should not have sent. The handler
    /// answers 200 anyway and writes nothing: a client that pings redundantly has a stale
    /// build, not an error worth surfacing.
    public var isNoOp: Bool {
        !firstPingEver && !firstToday && !firstThisMonth && !firstThisVersion && !firstPaidLaunch
    }

    /// Bounds on every attacker-controlled string that becomes part of a DynamoDB key.
    ///
    /// These exist because the values are *keys*, not payload: an unbounded string means
    /// unbounded distinct sort keys, which means a table that grows without limit and a stats
    /// response that grows with it. odvpn arrived at 20 bytes for versions the same way.
    ///
    /// Enforced by `PingHandler` (Phase 2), which truncates nothing and rejects instead —
    /// truncation would silently merge `2.10.0` and `2.10.0-beta.1`.
    public enum Limits {
        /// `appVersion` and `osVersion`, in bytes.
        public static let versionLength = 20
        /// Distinct `dimensions` entries in one request.
        public static let dimensionCount = 8
        /// A dimension name, in bytes. Also bounded by the config allowlist.
        public static let dimensionNameLength = 32
        /// A bucket label, in bytes.
        public static let dimensionValueLength = 32
    }
}

/// The response to `POST /v1/ping`: `{"ok":true}` and nothing else.
///
/// Reporting a count back would make a write-only endpoint readable, and `/v1/stats` already
/// publishes everything anyway — through a cache, which the ping path deliberately is not.
public struct PingAck: Encodable, Sendable, Equatable {
    public var ok: Bool

    public init(ok: Bool = true) {
        self.ok = ok
    }
}

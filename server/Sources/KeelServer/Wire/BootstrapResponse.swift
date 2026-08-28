#if canImport(FoundationEssentials)
public import FoundationEssentials
#else
public import Foundation
#endif

/// The response to `GET /v1/bootstrap`, as the server writes it.
///
/// The mirror of `KeelCore.BootstrapResponse`, which is `Decodable`. Generic over the opaque
/// `app` payload so that `KeelLambda` can use `BootstrapResponse<JSONValue>` — passing the app's
/// own config through untouched — while an app that builds its own handler can use a real type.
///
/// **Empty sections are omitted, not emitted as `{}` or `null`.** Absence means "no opinion" on
/// the other side, which is what makes a half-configured or rolled-back server degrade to the
/// client's compiled-in defaults instead of switching every feature off
/// (`docs/ARCHITECTURE.md` §1). Emitting empty containers would say the same thing in more
/// bytes, but it would also let a future reader mistake "no overrides" for "override with
/// nothing".
///
/// `telemetry` is the exception: always encoded, because an operator reading a response should
/// see the state of the ping kill switch rather than infer it from a missing key.
public struct BootstrapResponse<App: Encodable & Sendable>: Encodable, Sendable {
    public var schemaVersion: Int

    /// When this response was assembled — the *response*, not the config it came from. The
    /// client ages its disk cache by it.
    public var generatedAt: Date

    /// Flag overrides for the requesting client. Already resolved: the handler has applied the
    /// config item and then the `FEATURE_FLAGS` emergency override on top.
    ///
    /// There is no per-platform or per-version narrowing, here or in `RemoteConfig` — a flag that
    /// needs it is two flags, or one flag plus a check the client already makes (§10).
    public var features: [String: Bool]

    /// Version gate for the requesting build, or nil when the build is fine. Evaluated
    /// server-side against the `appVersion` in the query so the client compares nothing.
    public var gate: VersionGate?

    /// The ping kill switch and the dimension allowlist.
    public var telemetry: TelemetryConfig

    public var urls: [String: String]

    public var app: App?

    public init(
        schemaVersion: Int = Keel.schemaVersion,
        generatedAt: Date,
        features: [String: Bool] = [:],
        gate: VersionGate? = nil,
        telemetry: TelemetryConfig = .default,
        urls: [String: String] = [:],
        app: App? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.features = features
        self.gate = gate
        self.telemetry = telemetry
        self.urls = urls
        self.app = app
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, generatedAt, features, gate, telemetry, urls, app
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encodeISO8601(generatedAt, forKey: .generatedAt)
        if !features.isEmpty { try container.encode(features, forKey: .features) }
        try container.encodeIfPresent(gate, forKey: .gate)
        try container.encode(telemetry, forKey: .telemetry)
        if !urls.isEmpty { try container.encode(urls, forKey: .urls) }
        try container.encodeIfPresent(app, forKey: .app)
    }
}

// MARK: - Version gate

/// The kill switch, already evaluated for the requesting build.
///
/// The handler sends only what applies: a client on the current version gets no `gate` key at
/// all, rather than a gate it has to reason about. That keeps the comparison logic — semver, with
/// all its edge cases — on the side that can be fixed by a deploy.
public struct VersionGate: Encodable, Sendable, Equatable {
    public var minSupportedVersion: String?
    public var recommendedVersion: String?
    public var updateURL: String?
    public var maintenance: Maintenance?

    public init(
        minSupportedVersion: String? = nil,
        recommendedVersion: String? = nil,
        updateURL: String? = nil,
        maintenance: Maintenance? = nil
    ) {
        self.minSupportedVersion = minSupportedVersion
        self.recommendedVersion = recommendedVersion
        self.updateURL = updateURL
        self.maintenance = maintenance
    }

    /// True when this gate says nothing. The handler omits the whole section in that case.
    public var isEmpty: Bool {
        minSupportedVersion == nil && recommendedVersion == nil && updateURL == nil
            && maintenance == nil
    }
}

public struct Maintenance: Encodable, Sendable, Equatable {
    /// Shown verbatim to the user, so it is written by whoever runs the backend and is worth
    /// keeping short and specific.
    public var message: String

    public var until: Date?

    /// Default false — a hard block. A dismissible maintenance notice is a banner, and if that
    /// is what is wanted, `gate.recommendedVersion` is the banner.
    public var allowsDismissal: Bool

    public init(message: String, until: Date? = nil, allowsDismissal: Bool = false) {
        self.message = message
        self.until = until
        self.allowsDismissal = allowsDismissal
    }

    enum CodingKeys: String, CodingKey {
        case message, until, allowsDismissal
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(message, forKey: .message)
        try container.encodeISO8601IfPresent(until, forKey: .until)
        try container.encode(allowsDismissal, forKey: .allowsDismissal)
    }
}

// MARK: - Telemetry switch

/// Server-side control over the ping, per application, changed with `keel config set` and live
/// within the bootstrap cache TTL.
///
/// The same value gates both sides. The client reads it from its *cached* config and skips the
/// request; `PingHandler` reads it from the config item and writes nothing. Two enforcement
/// points because either alone is insufficient: the client's copy can be a shipped build that
/// never fetched bootstrap, and the server's copy cannot stop the request being made.
///
/// It can only turn collection **off**. The user's local opt-out is checked first on the client
/// and always wins — a remote switch able to re-enable collection for someone who declined
/// would make `docs/PRIVACY.md` false, which is not a trade worth any amount of data.
public struct TelemetryConfig: Encodable, Sendable, Equatable {
    /// Fails **open**: absent on the wire decodes to `true`. An unreachable or unconfigured
    /// backend must not silently stop counting, because "no data" and "no users" look
    /// identical afterwards and there is no way to tell them apart retroactively.
    ///
    /// If a deployment ever needs the opposite default — a legal or regional switch that must
    /// fail closed — that is a second, separately named flag, not a change to this one.
    public var isEnabled: Bool

    /// The dimension names the server will accept. Absent means "no constraint stated" and the
    /// client sends what it has.
    ///
    /// `BootstrapHandler` never emits `[]`: absence already says the backend has nothing to state
    /// about dimensions, and a client that sends one anyway has it dropped and logged rather than
    /// counted.
    ///
    /// `PingHandler` validates against the config's own allowlist regardless of what was
    /// advertised here, so this is an optimisation — it saves the bytes and the rejected
    /// write — and never the boundary.
    public var dimensions: [String]?

    public static let `default` = TelemetryConfig(isEnabled: true, dimensions: nil)

    /// The off switch, spelled out for tests and for `keel config set telemetry.enabled false`.
    public static let disabled = TelemetryConfig(isEnabled: false, dimensions: nil)

    public init(isEnabled: Bool = true, dimensions: [String]? = nil) {
        self.isEnabled = isEnabled
        self.dimensions = dimensions
    }

    enum CodingKeys: String, CodingKey {
        case isEnabled = "enabled"
        case dimensions
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encodeIfPresent(dimensions, forKey: .dimensions)
    }
}

// MARK: - Conventional URL keys

/// Conventional keys for `BootstrapResponse.urls`. Constants, not an enum: an app adds its own
/// key without touching the framework, and an unrecognised key is data rather than an error.
public enum KeelURL {
    public static let website = "website"
    public static let privacy = "privacy"
    public static let terms = "terms"
    public static let support = "support"
    public static let donation = "donation"
    public static let statusPage = "status"
}

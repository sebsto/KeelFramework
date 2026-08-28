#if canImport(FoundationEssentials)
public import FoundationEssentials
#else
public import Foundation
#endif

/// The product configuration, as stored in `CONFIG#current` and edited with `keel config set`.
///
/// This is **not** the bootstrap response. It is the raw material: the gate here holds thresholds
/// for every build, the telemetry section holds the bucket allowlists, and `BootstrapHandler`
/// projects the subset that applies to one requesting client (`docs/ARCHITECTURE.md` §3).
/// Keeping the two shapes apart is what lets the stored config carry things no client should
/// see — every platform's minimum version, every legal bucket label — without inventing a
/// filtering step inside the wire type.
///
/// Product configuration lives in the table rather than in the function's environment so it can
/// change without a deploy. Deployment knobs (`tableName`, window lengths) go the other way, into
/// `swift-configuration` (§7).
///
/// **Every field is optional and every decode is defaulted.** An operator edits this item by
/// hand or with a CLI, and a config that fails to decode because of one unexpected key would fall
/// back to compiled-in defaults — silently discarding every flag, URL and gate at once. Tolerant
/// decoding is the difference between "one section is ignored" and "the control surface is gone".
public struct RemoteConfig: Codable, Sendable, Equatable {
    /// Flag overrides, sent to every client that asks. Names are opaque `lower_snake_case`
    /// strings: the server keeps no list of known flags, so a flag can be configured before or
    /// after the build that reads it ships (Maxi80's rule, kept).
    ///
    /// There is no per-platform or per-version narrowing here. Flags that need it are two flags,
    /// or one flag plus a check the client already has to make; see §10.
    public var features: [String: Bool]

    /// Version gate thresholds for every build, unevaluated.
    public var gate: GateConfig?

    public var telemetry: TelemetrySettings

    /// Conventional keys in `KeelURL`, but any key is allowed — an unrecognised one is data.
    public var urls: [String: String]

    /// The app's own payload, carried through without being understood.
    public var app: JSONValue?

    /// When this item was last written. Informational: `keel config get` shows it, and it is the
    /// only history the item keeps (§4 — there is no audit trail on purpose).
    public var updatedAt: Date?

    /// A configuration that states nothing: what a freshly deployed stack behaves like, and what
    /// `ConfigCache` serves when the table cannot be read and nothing has been cached yet.
    ///
    /// Note that telemetry is *enabled* here. An empty config must not switch collection off, for
    /// the fail-open reason in `TelemetrySettings.isEnabled`.
    public static let empty = RemoteConfig()

    public init(
        features: [String: Bool] = [:],
        gate: GateConfig? = nil,
        telemetry: TelemetrySettings = .default,
        urls: [String: String] = [:],
        app: JSONValue? = nil,
        updatedAt: Date? = nil
    ) {
        self.features = features
        self.gate = gate
        self.telemetry = telemetry
        self.urls = urls
        self.app = app
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case features, gate, telemetry, urls, app, updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        features = try container.decodeIfPresent([String: Bool].self, forKey: .features) ?? [:]
        gate = try container.decodeIfPresent(GateConfig.self, forKey: .gate)
        telemetry =
            try container.decodeIfPresent(TelemetrySettings.self, forKey: .telemetry) ?? .default
        urls = try container.decodeIfPresent([String: String].self, forKey: .urls) ?? [:]
        app = try container.decodeIfPresent(JSONValue.self, forKey: .app)
        updatedAt = try container.decodeISO8601IfPresent(forKey: .updatedAt)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(features, forKey: .features)
        try container.encodeIfPresent(gate, forKey: .gate)
        try container.encode(telemetry, forKey: .telemetry)
        try container.encode(urls, forKey: .urls)
        try container.encodeIfPresent(app, forKey: .app)
        try container.encodeISO8601IfPresent(updatedAt, forKey: .updatedAt)
    }
}

// MARK: - Telemetry

/// The server's side of the ping switch: whether to count at all, and which distributions to
/// accept.
public struct TelemetrySettings: Codable, Sendable, Equatable {
    /// The kill switch. Decodes to `true` when absent, and `.default` is enabled.
    ///
    /// Fails open in every direction: an unconfigured table, a config item missing this section,
    /// and a config that could not be read all leave collection on. "No data" and "no users" are
    /// indistinguishable after the fact, and a switch that defaults to off turns a deployment
    /// mistake into a permanent hole in the numbers.
    ///
    /// It can only ever turn collection *off*. The user's local opt-out is checked first on the
    /// client and always wins (`docs/PRIVACY.md`).
    public var isEnabled: Bool

    /// The distributions this backend accepts, in declaration order.
    ///
    /// Doing double duty is deliberate: this is both the allowlist `PingHandler` validates
    /// against and the order `StatsHandler` publishes buckets in. One list means a dimension
    /// cannot be accepted but unpublishable, or published in an order nobody declared.
    public var dimensions: [DimensionConfig]

    public static let `default` = TelemetrySettings()

    /// The off switch, for tests and for `keel config set telemetry.enabled false`.
    public static let disabled = TelemetrySettings(isEnabled: false)

    public init(isEnabled: Bool = true, dimensions: [DimensionConfig] = []) {
        self.isEnabled = isEnabled
        self.dimensions = dimensions
    }

    enum CodingKeys: String, CodingKey {
        case isEnabled = "enabled"
        case dimensions
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        dimensions =
            try container.decodeIfPresent([DimensionConfig].self, forKey: .dimensions) ?? []
    }

    /// The declared dimension of that name, or nil if the backend does not accept it.
    public func dimension(named name: String) -> DimensionConfig? {
        dimensions.first { $0.name == name }
    }

    /// Whether a `(name, bucket)` pair may be written.
    ///
    /// Both halves are checked against the config, because both become part of a DynamoDB key:
    /// the name is a partition (`AGG#DIM#profiles#2026-08`) and the bucket is a sort key. An
    /// unchecked value here mints a partition per distinct client string, which nothing reads and
    /// nothing cleans up.
    public func accepts(dimension name: String, bucket: String) -> Bool {
        dimension(named: name)?.buckets.contains(bucket) ?? false
    }
}

/// One app-declared distribution: its name, and the exact set of bucket labels it may report.
///
/// The device buckets the raw number *before* the request, so the server never sees "this install
/// has exactly 7 profiles" even once (`docs/ARCHITECTURE.md` §9). This type is the server's half
/// of that agreement: the labels it will accept, and the order a chart should draw them in.
public struct DimensionConfig: Codable, Sendable, Equatable {
    /// Becomes part of a partition key, so keep it short and stable. Renaming it starts a new
    /// distribution rather than renaming the old one — the history stays under the old partition.
    public var name: String

    /// The allowlist *and* the display order — `["1-2", "3-5", "6-10", "11+"]`.
    ///
    /// Order matters and is not count order: a distribution whose axis has been sorted by
    /// frequency is misleading, so `StatsHandler` publishes buckets exactly as declared here.
    ///
    /// An empty list accepts nothing. That is a misconfiguration rather than a wildcard — a
    /// dimension that accepts any string is exactly the unbounded-partition problem the
    /// allowlist exists to prevent, so there is deliberately no way to spell it.
    public var buckets: [String]

    public init(name: String, buckets: [String]) {
        self.name = name
        self.buckets = buckets
    }
}

// MARK: - Version gate

/// Gate thresholds for every build, before evaluation.
///
/// `BootstrapHandler` compares the requesting `appVersion` against these and sends only what
/// applies, so the client never compares versions itself (§3). The comparison is the part with
/// the edge cases, and it belongs on the side a deploy can fix.
public struct GateConfig: Codable, Sendable, Equatable {
    /// Builds below this are blocked. Absent means nothing is blocked.
    public var minSupportedVersion: String?

    /// Builds below this see a dismissible prompt. Absent means no prompt.
    public var recommendedVersion: String?

    /// Where to send the user. Per-platform in practice, hence `platformOverrides`.
    public var updateURL: String?

    /// A backend-wide notice, independent of the client's version.
    public var maintenance: MaintenanceConfig?

    /// Overrides keyed by `Platform.rawValue`, merged field-by-field over the values above.
    ///
    /// This exists for one concrete reason: `updateURL` is not the same link on iOS, macOS and
    /// Android, and sending a Mac user to the iPhone App Store is a dead end. Minimum versions
    /// diverge for the same reason — an app's Android build is rarely on the same version as its
    /// iOS build.
    ///
    /// `maintenance` is deliberately *not* overridable. A backend outage is not per-platform, and
    /// a per-platform maintenance notice would be a way to express something that cannot be true.
    public var platformOverrides: [String: PlatformGateOverride]

    public init(
        minSupportedVersion: String? = nil,
        recommendedVersion: String? = nil,
        updateURL: String? = nil,
        maintenance: MaintenanceConfig? = nil,
        platformOverrides: [String: PlatformGateOverride] = [:]
    ) {
        self.minSupportedVersion = minSupportedVersion
        self.recommendedVersion = recommendedVersion
        self.updateURL = updateURL
        self.maintenance = maintenance
        self.platformOverrides = platformOverrides
    }

    enum CodingKeys: String, CodingKey {
        case minSupportedVersion, recommendedVersion, updateURL, maintenance, platformOverrides
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        minSupportedVersion = try container.decodeIfPresent(
            String.self, forKey: .minSupportedVersion)
        recommendedVersion = try container.decodeIfPresent(
            String.self, forKey: .recommendedVersion)
        updateURL = try container.decodeIfPresent(String.self, forKey: .updateURL)
        maintenance = try container.decodeIfPresent(MaintenanceConfig.self, forKey: .maintenance)
        platformOverrides =
            try container.decodeIfPresent(
                [String: PlatformGateOverride].self, forKey: .platformOverrides) ?? [:]
    }

    /// This gate with `platform`'s overrides applied and the override table dropped.
    ///
    /// A field the override does not mention keeps the base value, so an app that only needs a
    /// different `updateURL` per platform states that one field. Passing nil — a request that did
    /// not say which platform it is — yields the base values, which is the widest gate rather
    /// than no gate: a blocked build stays blocked when it fails to identify itself.
    public func resolved(for platform: Platform?) -> GateConfig {
        guard let platform, let override = platformOverrides[platform.rawValue] else {
            return GateConfig(
                minSupportedVersion: minSupportedVersion,
                recommendedVersion: recommendedVersion,
                updateURL: updateURL,
                maintenance: maintenance)
        }
        return GateConfig(
            minSupportedVersion: override.minSupportedVersion ?? minSupportedVersion,
            recommendedVersion: override.recommendedVersion ?? recommendedVersion,
            updateURL: override.updateURL ?? updateURL,
            maintenance: maintenance)
    }
}

/// The fields a platform may override on `GateConfig`. Every one is optional: absent means
/// "inherit", which is different from present-and-empty.
public struct PlatformGateOverride: Codable, Sendable, Equatable {
    public var minSupportedVersion: String?
    public var recommendedVersion: String?
    public var updateURL: String?

    public init(
        minSupportedVersion: String? = nil,
        recommendedVersion: String? = nil,
        updateURL: String? = nil
    ) {
        self.minSupportedVersion = minSupportedVersion
        self.recommendedVersion = recommendedVersion
        self.updateURL = updateURL
    }
}

/// A maintenance notice as stored: the same shape as the wire `Maintenance`, but `Codable`.
public struct MaintenanceConfig: Codable, Sendable, Equatable {
    public var message: String
    public var until: Date?

    /// Default false — a hard block, because that is what a maintenance notice is for. If the
    /// intent is a banner the user can dismiss, `recommendedVersion` is the banner.
    public var allowsDismissal: Bool

    public init(message: String, until: Date? = nil, allowsDismissal: Bool = false) {
        self.message = message
        self.until = until
        self.allowsDismissal = allowsDismissal
    }

    enum CodingKeys: String, CodingKey {
        case message, until, allowsDismissal
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        message = try container.decode(String.self, forKey: .message)
        until = try container.decodeISO8601IfPresent(forKey: .until)
        allowsDismissal =
            try container.decodeIfPresent(Bool.self, forKey: .allowsDismissal) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(message, forKey: .message)
        try container.encodeISO8601IfPresent(until, forKey: .until)
        try container.encode(allowsDismissal, forKey: .allowsDismissal)
    }

    /// The wire form.
    public var wireValue: Maintenance {
        Maintenance(message: message, until: until, allowsDismissal: allowsDismissal)
    }

    /// Whether this notice is still in force at `now`.
    ///
    /// An `until` in the past expires the notice, so an operator who set a window does not have
    /// to remember to clear it — the failure mode of a forgotten maintenance banner is an app
    /// that is blocked for no reason, which is worse than one that has to be blocked twice.
    public func isActive(at now: Date) -> Bool {
        guard let until else { return true }
        return now < until
    }
}

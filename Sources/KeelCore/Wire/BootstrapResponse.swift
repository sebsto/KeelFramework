#if canImport(FoundationEssentials)
public import FoundationEssentials
#else
public import Foundation
#endif

/// The response to `GET /v1/bootstrap` — everything the app needs to know at launch that it
/// should be able to change without an App Store release.
///
/// Generic over `App`, the opaque app-specific payload. An app with nothing extra to fetch
/// uses `BootstrapResponse<Empty>`; Maxi80's station metadata, odvpn's region list, and
/// anything else ride in `app` and are decoded by the app's own type.
///
/// **Every field except `schemaVersion` and `generatedAt` is optional or defaulted.** A
/// response missing a section means "no opinion", never "empty" — so a server that has not
/// been configured yet, or a rolled-back one, degrades to the client's compiled-in defaults
/// instead of switching every feature off (`docs/ARCHITECTURE.md` §1).
public struct BootstrapResponse<App: Decodable & Sendable>: Decodable, Sendable {
    /// The envelope version. A client tolerates a value *higher* than its own — unknown
    /// fields are ignored and the response still decodes — and rejects a lower one, which
    /// would mean the server rolled back past a field this build requires.
    public var schemaVersion: Int

    /// When the server assembled this response. Used to age the disk cache, not to expire
    /// it: a stale cached config still beats no config.
    public var generatedAt: Date

    /// Feature-flag overrides, keyed by the app's flag names. Absent means "no overrides",
    /// which leaves every flag at its compiled-in default.
    ///
    /// Applied wholesale rather than merged: a flag the server stops mentioning reverts to
    /// its default instead of leaving a stale override behind (`docs/ARCHITECTURE.md` §6).
    public var features: [String: Bool]

    /// Version gate and maintenance state. Absent means the build is fine.
    public var gate: VersionGate?

    /// Whether to send telemetry at all, and which dimensions the server will accept.
    ///
    /// This is the server-side switch for the ping. It can only *disable* — the user's local
    /// opt-out is checked first and always wins, because a remote switch that could
    /// re-enable collection for someone who turned it off would make `docs/PRIVACY.md`
    /// false. Defaults to enabled, so an unreachable server does not silently stop
    /// collection.
    public var telemetry: TelemetryConfig

    /// Well-known URLs the app links to, so they can be corrected without a release. Keys
    /// are conventional — see `KeelURL`.
    public var urls: [String: String]

    /// The app's own configuration, decoded by the app's own type. Absent when the server has
    /// no app payload configured.
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

    /// Written out rather than synthesized: the synthesized initializer would fail on an
    /// absent `features`/`telemetry`/`urls`, and those absences are the normal case.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        generatedAt = try container.decodeISO8601(forKey: .generatedAt)
        features = try container.decodeIfPresent([String: Bool].self, forKey: .features) ?? [:]
        gate = try container.decodeIfPresent(VersionGate.self, forKey: .gate)
        telemetry =
            try container.decodeIfPresent(TelemetryConfig.self, forKey: .telemetry) ?? .default
        urls = try container.decodeIfPresent([String: String].self, forKey: .urls) ?? [:]
        app = try container.decodeIfPresent(App.self, forKey: .app)
    }
}

// MARK: - Version gate

/// The kill switch. Every field is optional; an all-empty gate means "carry on".
public struct VersionGate: Decodable, Sendable, Equatable {
    /// Builds older than this cannot run — the client shows a blocking update screen. Use it
    /// for a build that is actively harmful (corrupts data, hammers an endpoint), not for one
    /// that is merely old.
    public var minSupportedVersion: String?

    /// Builds older than this get a dismissible nudge.
    public var recommendedVersion: String?

    /// Where to send the user to update. An App Store URL for a shipped app; absent means the
    /// client falls back to its compiled-in link.
    public var updateURL: String?

    /// Set to take the app offline with an explanation, independent of version. This is the
    /// lever for "the backend is broken, stop asking".
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
}

/// A scheduled or unscheduled outage the app should explain rather than fail through.
public struct Maintenance: Decodable, Sendable, Equatable {
    /// Shown to the user. Server-supplied, so it can be specific about what is wrong —
    /// which also means the client must treat it as untrusted text and never as markup.
    public var message: String

    /// When service is expected back, if known. The client shows a bare message when absent
    /// rather than inventing an estimate.
    public var until: Date?

    /// Whether the user can dismiss the notice and keep using the app. False — a hard
    /// block — is the default, because a maintenance notice that can be dismissed is
    /// indistinguishable from a warning banner.
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
}

// MARK: - Telemetry switch

/// Server-side control over the ping (`docs/ARCHITECTURE.md` §3).
public struct TelemetryConfig: Decodable, Sendable, Equatable {
    /// Whether to send the ping at all.
    ///
    /// Fails **open**: absent means `true`, so an unreachable or unconfigured server keeps
    /// collection running rather than silently stopping it. The flag's purpose is
    /// operational — cost, noise, a broken build spamming counters — and the same value is
    /// also honoured server-side, which is what makes it a real kill switch for builds that
    /// have already shipped.
    public var isEnabled: Bool

    /// Which `dimensions` keys the server will accept. Absent means "no constraint stated",
    /// and the client sends whatever it has.
    ///
    /// A Keel backend never sends an empty array — absence already says it has nothing to state,
    /// and `BootstrapHandler` omits the field rather than emitting `[]`. A client that receives
    /// one anyway treats it as "send none", which is the reading that matches the name.
    ///
    /// The server validates against its own copy of this list regardless, so this exists to
    /// save the client the bytes and the server the rejected request — not as the security
    /// boundary.
    public var dimensions: [String]?

    /// Enabled, no dimension constraint. What an absent `telemetry` section decodes to.
    public static let `default` = TelemetryConfig(isEnabled: true, dimensions: nil)

    /// The server-side off switch, spelled out for tests and for `keel config set`.
    public static let disabled = TelemetryConfig(isEnabled: false, dimensions: nil)

    public init(isEnabled: Bool = true, dimensions: [String]? = nil) {
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
        dimensions = try container.decodeIfPresent([String].self, forKey: .dimensions)
    }
}

// MARK: - Conventional URL keys

/// Conventional keys for `BootstrapResponse.urls`.
///
/// Constants rather than an enum so an app can add its own key without changing the
/// framework, and so an unknown key on the wire is data rather than a decoding failure.
public enum KeelURL {
    public static let website = "website"
    public static let privacy = "privacy"
    public static let terms = "terms"
    public static let support = "support"
    public static let donation = "donation"
    public static let statusPage = "status"
}

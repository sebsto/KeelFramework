public import Logging

#if canImport(FoundationEssentials)
public import FoundationEssentials
#else
public import Foundation
#endif

/// `GET /v1/bootstrap` — project the stored config onto one requesting client.
///
/// **It cannot fail.** `handle` is not throwing and returns no optional, because this is the
/// endpoint that carries the kill switch and the feature flags: a 500 here means every launching
/// app falls back to its compiled-in defaults at once. `ConfigCache` absorbs store failures
/// (fresh ▸ loaded ▸ stale ▸ fallback) and every remaining decision degrades rather than throws —
/// an unrecognised platform yields the base gate, an unparseable version yields no gate at all.
///
/// The projection is the interesting part. The stored config holds thresholds for every build and
/// every platform; the response holds only what applies to the caller, so the client compares
/// nothing (`docs/ARCHITECTURE.md` §3).
public struct BootstrapHandler: Sendable {
    /// What the handler needs from the query string.
    ///
    /// The contract also reserves `os` and `locale`. This build reads neither: there is no
    /// per-OS or per-locale narrowing, and parsing a parameter into a field nothing consults
    /// would only suggest otherwise. Unknown parameters are ignored, so a client that sends them
    /// is not an error — see §10 for where narrowing would go.
    public struct Request: Sendable, Equatable {
        /// The caller's build, or nil if it did not say. Nil yields an un-gated response: the
        /// gate's whole job is a comparison, and there is nothing to compare against.
        public var appVersion: String?

        /// Selects the per-platform gate overrides. Nil — including an unrecognised value —
        /// yields the base gate rather than none, so a build that fails to identify itself is
        /// still blocked if the base threshold blocks it.
        public var platform: Platform?

        public init(appVersion: String? = nil, platform: Platform? = nil) {
            self.appVersion = appVersion
            self.platform = platform
        }

        /// Reads the documented query parameters, tolerating everything else.
        ///
        /// An unknown `platform` value becomes nil instead of a 400. That is the opposite of
        /// `/v1/ping`, deliberately: ping's platform becomes a partition key and must be a closed
        /// set, while bootstrap's only affects which overrides apply — and refusing to serve
        /// config to a client whose platform this build has not heard of would break the newer
        /// client rather than the older server.
        public init(query: [String: String]) {
            self.init(
                appVersion: query["appVersion"],
                platform: query["platform"].flatMap(Platform.init(rawValue:)))
        }
    }

    let cache: ConfigCache
    let flagOverride: FeatureFlagsOverride
    let clock: @Sendable () -> Date
    let logger: Logger

    public init(
        cache: ConfigCache,
        flagOverride: FeatureFlagsOverride = .none,
        clock: @escaping @Sendable () -> Date = { Date() },
        logger: Logger = Logger(label: "keel.bootstrap")
    ) {
        self.cache = cache
        self.flagOverride = flagOverride
        self.clock = clock
        self.logger = logger
        if !flagOverride.malformedEntries.isEmpty {
            // Logged once at construction rather than per request: the variable does not change
            // for the life of the function, and a warning on every invocation would be noise
            // that buries the next real one. Dropped, never fatal — see `FeatureFlagsOverride`.
            logger.warning(
                "Ignoring malformed \(FeatureFlagsOverride.environmentKey) entries",
                metadata: [
                    "entries": .string(flagOverride.malformedEntries.joined(separator: ", "))
                ]
            )
        }
    }

    public func handle(_ request: Request) async -> BootstrapResponse<JSONValue> {
        let config = await cache.current()
        let now = clock()
        return BootstrapResponse(
            generatedAt: now,
            features: flagOverride.applied(to: config.features),
            gate: gate(from: config, request: request, now: now),
            telemetry: telemetry(from: config),
            urls: config.urls,
            app: config.app)
    }

    // MARK: - Projection

    /// The wire telemetry section: the switch, plus the names the backend will accept.
    ///
    /// `dimensions` is emitted only when the config declares some. An empty array is never sent —
    /// absent already says "this backend has nothing to say about dimensions", and a client that
    /// sends one anyway has it dropped with a warning rather than counted, so the field is an
    /// optimisation and never the boundary.
    func telemetry(from config: RemoteConfig) -> TelemetryConfig {
        let declared = config.telemetry.dimensions.map(\.name)
        return TelemetryConfig(
            isEnabled: config.telemetry.isEnabled,
            dimensions: declared.isEmpty ? nil : declared)
    }

    /// The gate as it applies to this caller, or nil when nothing does.
    ///
    /// Two independent parts. **Maintenance** is version-independent and applies to everyone, as
    /// long as its window has not closed. **Version thresholds** are included only when the
    /// caller's build is actually below them, which is what makes presence meaningful on the
    /// client: `minSupportedVersion` present means "you are blocked", `recommendedVersion` present
    /// means "you should update". A caller below both gets both, and the client's precedence rule
    /// is that blocking wins.
    ///
    /// An unparseable `appVersion` yields no thresholds. Failing open is the only safe direction:
    /// the alternative is blocking every install of a build whose version string this parser has
    /// not met.
    func gate(from config: RemoteConfig, request: Request, now: Date) -> VersionGate? {
        guard let stored = config.gate else { return nil }
        let resolved = stored.resolved(for: request.platform)

        let maintenance = resolved.maintenance.flatMap {
            $0.isActive(at: now) ? $0.wireValue : nil
        }

        var minimum: String?
        var recommended: String?
        if let raw = request.appVersion, let caller = SemanticVersion(raw) {
            minimum = threshold(
                resolved.minSupportedVersion, named: "minSupportedVersion", above: caller)
            recommended = threshold(
                resolved.recommendedVersion, named: "recommendedVersion", above: caller)
        } else if request.appVersion != nil {
            logger.debug("Un-gated response: appVersion is not a version this build can order")
        }

        let gate = VersionGate(
            minSupportedVersion: minimum,
            recommendedVersion: recommended,
            // Only worth sending when there is something to update to. A maintenance notice on
            // its own is not an update prompt, and a URL beside it would invite a button that
            // sends the user to the store to fix an outage they cannot fix.
            updateURL: (minimum == nil && recommended == nil) ? nil : resolved.updateURL,
            maintenance: maintenance)
        return gate.isEmpty ? nil : gate
    }

    /// `value` if `caller` is below it, else nil — the "does this apply to you" test.
    ///
    /// A threshold the parser cannot read is treated as absent, so a typo in the config cannot
    /// block anyone. It is logged at warning level, because a `minSupportedVersion` that silently
    /// does nothing is the failure mode an operator is least likely to notice on their own.
    private func threshold(
        _ value: String?, named field: String, above caller: SemanticVersion
    ) -> String? {
        guard let value else { return nil }
        guard let parsed = SemanticVersion(value) else {
            logger.warning(
                "Ignoring an unreadable gate threshold",
                metadata: ["field": .string(field), "value": .string(value)])
            return nil
        }
        return caller < parsed ? value : nil
    }
}

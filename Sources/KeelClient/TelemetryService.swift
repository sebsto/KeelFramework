import Foundation
public import KeelCore

/// The launch ping, end to end: guards, dedup, send, persist — in that order, and the
/// order is most of the design.
///
/// Orthanc's `LaunchCoordinator` and odvpn's `StatsClient` merged, keeping each one's
/// correct half. Dedup state persists only *after* the send returns (Orthanc's rule —
/// odvpn persists first and silently drops a day on failure), and the paid ratchet latches
/// only on an *accepted* ping (also Orthanc — a conversion is once per install, so a
/// dropped one must re-offer itself next launch).
///
/// Call `run(licenseState:)` from a launch `.task`, after — or racing — the bootstrap
/// fetch; it reads the telemetry section it is handed, which is the *cached* config, so
/// there is no ordering dependency on the network.
public struct TelemetryService: Sendable {
    /// The `UserDefaults` keys, name-spaced and stable — a rename orphans state and
    /// re-fires every "first".
    public enum Key {
        /// The user's opt-out. **Absent means enabled** (`docs/PRIVACY.md`): the toggle
        /// only writes when touched, and reading absent as false would disable telemetry
        /// for everyone who never opened Settings.
        public static let isEnabled = "keel.telemetry.isEnabled"
        public static let lastPingDate = "keel.telemetry.lastPingDate"
        public static let lastPingVersion = "keel.telemetry.lastPingVersion"
        public static let hasPingedPaid = "keel.telemetry.hasPingedPaid"
    }

    private let configuration: KeelConfiguration
    private let client: BackendClient

    public init(configuration: KeelConfiguration) {
        self.configuration = configuration
        self.client = configuration.client
    }

    /// Whether the user has telemetry on. Reads the tri-state key honestly.
    public var isUserEnabled: Bool {
        configuration.defaults.bool(forKey: Key.isEnabled) ?? true
    }

    /// Send the launch ping if there is anything to say and nothing forbids it.
    ///
    /// The guard order is a policy statement, not an optimisation:
    /// 1. **The user's opt-out wins over everything**, including the server. A remote
    ///    switch able to re-enable collection for someone who declined would make
    ///    `docs/PRIVACY.md` false.
    /// 2. **Demo mode sends nothing.** App Review expects offline operation in demo.
    /// 3. **The server's kill switch**, read from the cached config handed in — off means
    ///    no request, not an errored one.
    ///
    /// `dimensions` carries the app's pre-bucketed distributions; entries the server does
    /// not advertise in `telemetry.dimensions` are dropped here, saving the bytes and the
    /// server-side rejection. The server validates against its own list regardless.
    public func run(
        licenseState: LicenseState,
        dimensions: [String: String] = [:],
        telemetry: TelemetryConfig = .default
    ) async {
        guard isUserEnabled else { return }
        guard !configuration.isDemoMode() else { return }
        guard telemetry.isEnabled else {
            configuration.log.debug("Telemetry is disabled server-side; not pinging")
            return
        }

        let defaults = configuration.defaults
        let now = configuration.now()
        let flags = PingFlags.compute(
            lastPing: defaults.date(forKey: Key.lastPingDate),
            lastVersion: defaults.string(forKey: Key.lastPingVersion),
            hasPingedPaid: defaults.bool(forKey: Key.hasPingedPaid) ?? false,
            licenseState: licenseState,
            appVersion: configuration.appVersion,
            now: now)
        guard !flags.isNoOp else { return }

        let request = flags.request(
            appVersion: configuration.appVersion,
            osVersion: configuration.osVersion,
            platform: configuration.platform,
            licenseState: licenseState,
            dimensions: accepted(dimensions, by: telemetry))

        guard await client.send(ping: request) else {
            // Nothing persists: the same booleans re-offer themselves next launch, which
            // is the whole recovery mechanism. Persisting first would silently drop a day.
            configuration.log.debug("Ping not accepted; dedup state left unchanged")
            return
        }

        defaults.set(now, forKey: Key.lastPingDate)
        defaults.set(configuration.appVersion, forKey: Key.lastPingVersion)
        if flags.firstPaidLaunch {
            // Latched only here, on acceptance, and never cleared — a refund followed by
            // a re-purchase is not a second conversion.
            defaults.set(true, forKey: Key.hasPingedPaid)
        }
    }

    /// The user's toggle, for a settings screen that does not use `TelemetryToggle`.
    public func setUserEnabled(_ isEnabled: Bool) {
        configuration.defaults.set(isEnabled, forKey: Key.isEnabled)
    }

    /// The dimensions the server advertised it will accept, in the request's shape.
    ///
    /// Nil advertised means "no constraint stated" and everything goes; an advertised
    /// list filters by name. Nil out of empty in, because the wire omits the key.
    private func accepted(
        _ dimensions: [String: String], by telemetry: TelemetryConfig
    ) -> [String: String]? {
        guard !dimensions.isEmpty else { return nil }
        guard let advertised = telemetry.dimensions else { return dimensions }
        let filtered = dimensions.filter { advertised.contains($0.key) }
        return filtered.isEmpty ? nil : filtered
    }
}

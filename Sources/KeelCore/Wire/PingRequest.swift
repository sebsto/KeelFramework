/// The body of `POST /v1/ping`.
///
/// **Truly anonymous.** Five booleans, three short strings, and optional pre-bucketed
/// dimension values. There is no field here that could carry a device identifier, and no code
/// in `KeelCore` derives one — see `docs/adr/0004-client-side-dedup-no-identifier.md`. Adding
/// one is a privacy-policy change first and a code change second.
///
/// Deduplication is entirely client-side: `PingFlags` computes the five booleans from local
/// state and a UTC clock, and the server trusts them, only ever issuing `UpdateItem ADD` on a
/// shared counter. That is what lets the counts be right without knowing who anyone is.
///
/// `Encodable` only. The client sends this and never receives it; the server's own copy is
/// the decoding side. Their agreement is pinned by the golden fixtures both test suites read.
public struct PingRequest: Encodable, Sendable, Equatable {
    /// First launch ever on this install. Drives `AGG#INSTALLS`.
    public var firstPingEver: Bool

    /// First launch today, UTC. Drives `AGG#DAU` and its license-state cohort.
    public var firstToday: Bool

    /// First launch this month, UTC. Drives `AGG#MAU` and its cohort.
    public var firstThisMonth: Bool

    /// First launch since `appVersion` changed. Drives the version spread independently of
    /// the monthly clock, so a same-device upgrade registers immediately instead of waiting
    /// for a new month.
    public var firstThisVersion: Bool

    /// True exactly once per install: the first launch on which the app observed a paid
    /// state. Drives `AGG#CONVERSIONS`.
    ///
    /// The client latches this only on a ping the server *accepted*, because a conversion is
    /// once-per-install — a dropped one is lost forever, unlike a daily boolean that re-fires
    /// tomorrow.
    public var firstPaidLaunch: Bool

    /// e.g. `2.1.0`. Capped at 20 ASCII bytes by the server.
    public var appVersion: String

    /// e.g. `26.1` — major.minor is enough, and a full build number would narrow a device
    /// more than the OS spread needs.
    public var osVersion: String

    public var platform: Platform

    public var licenseState: LicenseState

    /// App-specific distributions as **pre-bucketed** strings: `["profiles": "3-5"]`, never
    /// `["profiles": "4"]`. The raw number never leaves the device, so the server cannot see
    /// an exact count even in a single request.
    ///
    /// Omitted entirely when empty. Both names and values are validated server-side against
    /// the allowlist in the remote config, so a client typo cannot create an orphan
    /// `AGG#DIM#<typo>` partition.
    public var dimensions: [String: String]?

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
        dimensions: [String: String]? = nil
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
        self.dimensions = dimensions?.isEmpty == true ? nil : dimensions
    }

    /// True when no counter would move. The client checks this and skips the request
    /// entirely — after the first launch of a day, a ping costs nothing at all
    /// (`docs/ARCHITECTURE.md` §11).
    public var isNoOp: Bool {
        !firstPingEver && !firstToday && !firstThisMonth && !firstThisVersion && !firstPaidLaunch
    }
}

/// The response to `POST /v1/ping`. Deliberately says nothing: a body that reported counts
/// back would turn a write-only endpoint into a way to observe other people's data.
public struct PingAck: Decodable, Sendable, Equatable {
    public var ok: Bool

    public init(ok: Bool) {
        self.ok = ok
    }
}

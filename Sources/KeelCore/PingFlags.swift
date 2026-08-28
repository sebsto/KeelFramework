#if canImport(FoundationEssentials)
public import FoundationEssentials
#else
public import Foundation
#endif

/// The five deduplication booleans, computed from what the device remembers.
///
/// This is the whole privacy mechanism in one pure function (`docs/adr/0004`): the server
/// keeps no per-device state, so *the device* decides whether this launch is a first — and
/// the two existing implementations of that decision disagreed in the details. Orthanc and
/// odvpn each hand-rolled it; this is the reconciled version, and being pure is the point:
/// every calendar edge is a table-driven test with an injected clock.
///
/// All comparisons are UTC civil dates, matching the server's counter stamps. A user flying
/// through timezones pings once per *UTC* day, the same day the counter is filed under.
public struct PingFlags: Sendable, Equatable {
    /// Never pinged before — this install has no memory of one.
    ///
    /// Honest about its own limits: a reinstall or a cleared container counts again, and
    /// `installs` therefore over-counts. That is the accuracy trade for having no
    /// identifier, and it is documented rather than corrected.
    public var firstPingEver: Bool

    public var firstToday: Bool
    public var firstThisMonth: Bool

    /// First launch since the version string changed, independent of the monthly clock —
    /// what moves the version spread on a same-day upgrade.
    public var firstThisVersion: Bool

    /// First launch ever in a paid state. A once-per-install ratchet: true only until a
    /// ping carrying it is *accepted*, and never true again after (`TelemetryService`
    /// latches `hasPingedPaid` on the accepted send, so a refund-then-repurchase does not
    /// count twice).
    public var firstPaidLaunch: Bool

    public init(
        firstPingEver: Bool = false,
        firstToday: Bool = false,
        firstThisMonth: Bool = false,
        firstThisVersion: Bool = false,
        firstPaidLaunch: Bool = false
    ) {
        self.firstPingEver = firstPingEver
        self.firstToday = firstToday
        self.firstThisMonth = firstThisMonth
        self.firstThisVersion = firstThisVersion
        self.firstPaidLaunch = firstPaidLaunch
    }

    /// Nothing to say — the request is not sent at all. The second launch of a day costs
    /// zero requests, which is what keeps the backend's cost model flat.
    public var isNoOp: Bool {
        !firstPingEver && !firstToday && !firstThisMonth && !firstThisVersion
            && !firstPaidLaunch
    }

    /// Compute the flags for a launch.
    ///
    /// - Parameters:
    ///   - lastPing: when this install last pinged, or nil if it never has.
    ///   - lastVersion: the `appVersion` sent with that ping.
    ///   - hasPingedPaid: whether a paid-state ping was ever *accepted* — the ratchet.
    ///   - licenseState: the state observed right now.
    ///   - appVersion: the running build.
    ///   - now: injected, so every calendar edge is testable.
    /// - Returns: the five booleans for this launch, possibly all false — check `isNoOp`.
    public static func compute(
        lastPing: Date?,
        lastVersion: String?,
        hasPingedPaid: Bool,
        licenseState: LicenseState,
        appVersion: String,
        now: Date
    ) -> PingFlags {
        let isPaid = licenseState == .paid
        guard let lastPing else {
            return PingFlags(
                firstPingEver: true,
                firstToday: true,
                firstThisMonth: true,
                firstThisVersion: true,
                firstPaidLaunch: isPaid && !hasPingedPaid)
        }
        return PingFlags(
            firstPingEver: false,
            firstToday: !UTCDate.isSameDay(lastPing, now),
            firstThisMonth: !UTCDate.isSameMonth(lastPing, now),
            // `lastVersion == nil` with a lastPing date means an upgrade from a build that
            // did not record versions yet; count it, or the spread misses every migrated
            // install's current version until its next monthly census.
            firstThisVersion: lastVersion != appVersion,
            firstPaidLaunch: isPaid && !hasPingedPaid)
    }

    /// The wire request these flags describe.
    public func request(
        appVersion: String,
        osVersion: String,
        platform: Platform,
        licenseState: LicenseState,
        dimensions: [String: String]? = nil
    ) -> PingRequest {
        PingRequest(
            firstPingEver: firstPingEver,
            firstToday: firstToday,
            firstThisMonth: firstThisMonth,
            firstThisVersion: firstThisVersion,
            firstPaidLaunch: firstPaidLaunch,
            appVersion: appVersion,
            osVersion: osVersion,
            platform: platform,
            licenseState: licenseState,
            dimensions: dimensions)
    }
}

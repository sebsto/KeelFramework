import Foundation
import Testing

@testable import KeelCore

/// The one piece both existing apps got subtly different, so every row here is a decision:
/// UTC civil days (not 24-hour windows), version change independent of the monthly clock,
/// and a paid ratchet that latches on acceptance, not on attempt.
@Suite("Ping flags")
struct PingFlagsTests {

    /// 2026-08-24T10:00:00Z.
    static let now = UTCDate.date(year: 2026, month: 8, day: 24).addingTimeInterval(10 * 3_600)

    private static func compute(
        lastPing: Date?,
        lastVersion: String? = "2.1.0",
        hasPingedPaid: Bool = false,
        licenseState: LicenseState = .free,
        appVersion: String = "2.1.0",
        now: Date = now
    ) -> PingFlags {
        PingFlags.compute(
            lastPing: lastPing,
            lastVersion: lastVersion,
            hasPingedPaid: hasPingedPaid,
            licenseState: licenseState,
            appVersion: appVersion,
            now: now)
    }

    @Test("A device with no memory of a ping is first at everything")
    func firstEver() {
        let flags = Self.compute(lastPing: nil, lastVersion: nil)
        #expect(
            flags
                == PingFlags(
                    firstPingEver: true, firstToday: true, firstThisMonth: true,
                    firstThisVersion: true))
    }

    @Test("A second launch the same UTC day says nothing at all")
    func sameDayIsNoOp() {
        let flags = Self.compute(lastPing: Self.now.addingTimeInterval(-3_600))
        #expect(flags.isNoOp)
        // No request is the assertion: the second launch of a day costs zero.
    }

    @Test("UTC midnight is the day boundary, not 24 hours since the last ping")
    func utcMidnightBounds() {
        // 23:30 yesterday UTC → 00:30 today UTC is one hour apart and two different days.
        let yesterdayLate = UTCDate.date(year: 2026, month: 8, day: 23)
            .addingTimeInterval(23 * 3_600 + 1_800)
        let todayEarly = UTCDate.date(year: 2026, month: 8, day: 24).addingTimeInterval(1_800)
        let flags = Self.compute(lastPing: yesterdayLate, now: todayEarly)
        #expect(flags.firstToday)
        #expect(!flags.firstThisMonth)

        // 22 hours apart within the same UTC day is still the same day.
        let sameDay = Self.compute(
            lastPing: UTCDate.date(year: 2026, month: 8, day: 24).addingTimeInterval(600),
            now: UTCDate.date(year: 2026, month: 8, day: 24).addingTimeInterval(22 * 3_600))
        #expect(!sameDay.firstToday)
    }

    @Test("A month boundary fires both the day and the month")
    func monthBoundary() {
        let flags = Self.compute(lastPing: UTCDate.date(year: 2026, month: 7, day: 31))
        #expect(flags.firstToday)
        #expect(flags.firstThisMonth)
        #expect(!flags.firstPingEver)
    }

    @Test("The same day-of-month a year later is a different month")
    func yearBoundary() {
        // `isSameMonth` comparing only the month number would call 2025-08 and 2026-08 the
        // same month; the year is part of the identity.
        let flags = Self.compute(lastPing: UTCDate.date(year: 2025, month: 8, day: 24))
        #expect(flags.firstThisMonth)
    }

    @Test("An upgrade fires the version flag even on the same day")
    func versionChangeSameDay() {
        let flags = Self.compute(
            lastPing: Self.now.addingTimeInterval(-600),
            lastVersion: "2.0.0",
            appVersion: "2.1.0")
        #expect(flags.firstThisVersion)
        #expect(!flags.firstToday)
        #expect(!flags.isNoOp)
    }

    @Test("A device that pinged before versions were recorded counts its version once")
    func migratedInstall() {
        let flags = Self.compute(lastPing: Self.now.addingTimeInterval(-600), lastVersion: nil)
        // Absent-but-pinged means an upgrade from a build predating the version record;
        // skipping it would hide every migrated install's version until the next census.
        #expect(flags.firstThisVersion)
    }

    @Test("The paid ratchet fires only while unlatched, whatever the calendar says")
    func paidRatchet() {
        let unlatched = Self.compute(
            lastPing: Self.now.addingTimeInterval(-600),
            hasPingedPaid: false,
            licenseState: .paid)
        #expect(unlatched.firstPaidLaunch)
        #expect(!unlatched.isNoOp)

        let latched = Self.compute(
            lastPing: Self.now.addingTimeInterval(-600),
            hasPingedPaid: true,
            licenseState: .paid)
        #expect(!latched.firstPaidLaunch)
        #expect(latched.isNoOp)
    }

    @Test("Free and trial states never fire the conversion, latched or not")
    func onlyPaidConverts() {
        for state in [LicenseState.free, .trial] {
            let flags = Self.compute(lastPing: nil, licenseState: state)
            #expect(!flags.firstPaidLaunch)
        }
    }

    @Test("The request built from the flags carries them verbatim")
    func requestCarriesFlags() {
        let request = PingFlags(firstToday: true, firstThisVersion: true).request(
            appVersion: "2.1.0",
            osVersion: "26.1",
            platform: .macOS,
            licenseState: .trial,
            dimensions: ["profiles": "3-5"])
        #expect(request.firstToday)
        #expect(request.firstThisVersion)
        #expect(!request.firstPingEver)
        #expect(request.platform == .macOS)
        #expect(request.licenseState == .trial)
        #expect(request.dimensions == ["profiles": "3-5"])
    }
}

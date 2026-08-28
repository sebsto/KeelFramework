import Foundation
import Testing

@testable import KeelServer

/// `UTCDate` decides which counter a launch belongs to and produces every sort key in the table,
/// so an off-by-one here is silently wrong data rather than a crash.
///
/// The mirror of this suite in `KeelCoreTests` runs the same cases against the client's copy of
/// the file, which is how the two stay identical.
@Suite("UTC date arithmetic")
struct UTCDateTests {

    /// One known day number and the civil date it must be. A named type rather than a tuple so
    /// a failure names the case instead of printing four bare integers.
    struct CivilCase: Sendable, CustomTestStringConvertible {
        var days: Int
        var year: Int
        var month: Int
        var day: Int
        var note: String

        var testDescription: String { "\(days) days = \(year)-\(month)-\(day) (\(note))" }
    }

    /// Cross-checks against a `Calendar` are deliberately absent: `Calendar` is unavailable in
    /// `FoundationEssentials`, which is the reason this code exists. The expected values below
    /// are known dates, not another implementation's output.
    @Test(
        "Civil components round-trip against known days since the epoch",
        arguments: [
            CivilCase(days: 0, year: 1970, month: 1, day: 1, note: "the epoch"),
            CivilCase(days: 1, year: 1970, month: 1, day: 2, note: "the day after"),
            CivilCase(
                days: -1, year: 1969, month: 12, day: 31,
                note: "pre-epoch, where truncating division goes wrong"),
            CivilCase(days: 59, year: 1970, month: 3, day: 1, note: "non-leap February"),
            CivilCase(days: 365, year: 1971, month: 1, day: 1, note: "year boundary"),
            CivilCase(
                days: 11_016, year: 2000, month: 2, day: 29,
                note: "a century that is a leap year"),
            CivilCase(days: 20_689, year: 2026, month: 8, day: 24, note: "today"),
            CivilCase(
                days: -719_162, year: 1, month: 1, day: 1, note: "proleptic Gregorian year 1"),
        ])
    func civilRoundTrips(testCase: CivilCase) {
        let civil = UTCDate.civil(fromDaysSinceEpoch: testCase.days)
        #expect(civil.year == testCase.year)
        #expect(civil.month == testCase.month)
        #expect(civil.day == testCase.day)
        #expect(
            UTCDate.daysSinceEpoch(
                year: testCase.year, month: testCase.month, day: testCase.day) == testCase.days)
    }

    @Test("Every day for twelve years round-trips, including both leap-year rules")
    func civilRoundTripsExhaustively() {
        // 1996-2008 spans a leap year, a non-leap year divisible by 4 (none in range, so also
        // 2100 below), and 2000 — the century that *is* a leap year. Cheap enough to brute force.
        for days in 9_496...14_000 {
            let civil = UTCDate.civil(fromDaysSinceEpoch: days)
            #expect(
                UTCDate.daysSinceEpoch(year: civil.year, month: civil.month, day: civil.day)
                    == days)
        }
        // 2100-02-28 → 2100-03-01: a year divisible by 4 and 100 but not 400.
        #expect(UTCDate.dayStamp(UTCDate.date(year: 2100, month: 2, day: 28)) == "2100-02-28")
        let dayAfter = UTCDate.daysSinceEpoch(year: 2100, month: 2, day: 28) + 1
        let next = UTCDate.civil(fromDaysSinceEpoch: dayAfter)
        #expect((next.year, next.month, next.day) == (2100, 3, 1))
    }

    @Test("Day and month stamps are zero-padded, because they are sorted as strings")
    func stampsArePadded() {
        // Unpadded stamps would sort "2026-1-9" after "2026-10-1", which breaks every range
        // query and every chart at once.
        #expect(UTCDate.dayStamp(UTCDate.date(year: 2026, month: 1, day: 9)) == "2026-01-09")
        #expect(UTCDate.monthStamp(UTCDate.date(year: 2026, month: 1, day: 9)) == "2026-01")
        #expect(UTCDate.dayStamp(UTCDate.date(year: 2026, month: 12, day: 31)) == "2026-12-31")
    }

    @Test("Sub-day instants land on the right day, at both ends of it")
    func stampsUseWholeDays() {
        let midnight = UTCDate.date(year: 2026, month: 8, day: 24)
        #expect(UTCDate.dayStamp(midnight) == "2026-08-24")
        #expect(UTCDate.dayStamp(midnight.addingTimeInterval(1)) == "2026-08-24")
        #expect(UTCDate.dayStamp(midnight.addingTimeInterval(86_399)) == "2026-08-24")
        #expect(UTCDate.dayStamp(midnight.addingTimeInterval(86_400)) == "2026-08-25")
        // One second before midnight is the *previous* day. Truncating division would call it
        // 2026-08-24 and lose a day's ping for anyone launching at 23:59:59 UTC.
        #expect(UTCDate.dayStamp(midnight.addingTimeInterval(-1)) == "2026-08-23")
    }

    @Test("Same-day and same-month comparisons are what the ping dedup relies on")
    func sameDayAndMonth() throws {
        let morning = try #require(UTCDate.date(fromISO8601: "2026-08-24T00:00:01Z"))
        let evening = try #require(UTCDate.date(fromISO8601: "2026-08-24T23:59:59Z"))
        let nextDay = try #require(UTCDate.date(fromISO8601: "2026-08-25T00:00:00Z"))
        let nextMonth = try #require(UTCDate.date(fromISO8601: "2026-09-01T00:00:00Z"))
        let nextYear = try #require(UTCDate.date(fromISO8601: "2027-08-24T00:00:00Z"))

        #expect(UTCDate.isSameDay(morning, evening))
        #expect(!UTCDate.isSameDay(evening, nextDay))
        #expect(UTCDate.isSameMonth(morning, nextDay))
        #expect(!UTCDate.isSameMonth(evening, nextMonth))
        // Same month number, different year — the case a naive month comparison gets wrong.
        #expect(!UTCDate.isSameMonth(morning, nextYear))
    }

    @Test("monthsAgo lands on the first of the month and carries across years")
    func monthsAgoCarries() {
        let august = UTCDate.date(year: 2026, month: 8, day: 24)
        #expect(UTCDate.monthStamp(UTCDate.monthsAgo(0, from: august)) == "2026-08")
        #expect(UTCDate.monthStamp(UTCDate.monthsAgo(1, from: august)) == "2026-07")
        #expect(UTCDate.monthStamp(UTCDate.monthsAgo(8, from: august)) == "2025-12")
        #expect(UTCDate.monthStamp(UTCDate.monthsAgo(12, from: august)) == "2025-08")
        #expect(UTCDate.monthStamp(UTCDate.monthsAgo(25, from: august)) == "2024-07")
        #expect(UTCDate.dayStamp(UTCDate.monthsAgo(1, from: august)) == "2026-07-01")
    }

    @Test("daysAgo crosses month, year, and leap-day boundaries")
    func daysAgoCarries() {
        let march = UTCDate.date(year: 2026, month: 3, day: 2)
        #expect(UTCDate.dayStamp(UTCDate.daysAgo(1, from: march)) == "2026-03-01")
        #expect(UTCDate.dayStamp(UTCDate.daysAgo(2, from: march)) == "2026-02-28")
        // 2024 is a leap year, so the same offset lands on the 29th.
        let leapMarch = UTCDate.date(year: 2024, month: 3, day: 2)
        #expect(UTCDate.dayStamp(UTCDate.daysAgo(2, from: leapMarch)) == "2024-02-29")

        let january = UTCDate.date(year: 2026, month: 1, day: 1)
        #expect(UTCDate.dayStamp(UTCDate.daysAgo(1, from: january)) == "2025-12-31")
        #expect(UTCDate.dayStamp(UTCDate.daysAgo(0, from: january)) == "2026-01-01")
    }

    // MARK: - ISO 8601

    @Test("Formatting is always UTC, always second precision, always Z-suffixed")
    func iso8601Formatting() {
        let date = UTCDate.date(year: 2026, month: 8, day: 24).addingTimeInterval(10 * 3_600)
        #expect(UTCDate.iso8601String(date) == "2026-08-24T10:00:00Z")
        #expect(UTCDate.iso8601String(Date(timeIntervalSince1970: 0)) == "1970-01-01T00:00:00Z")
        // Sub-second detail is dropped rather than rendered: it is noise in a `generatedAt`, and
        // it would change the bytes of every fixture.
        #expect(UTCDate.iso8601String(date.addingTimeInterval(0.7)) == "2026-08-24T10:00:00Z")
        // Pre-epoch, where the day must floor and the time-of-day must not go negative.
        #expect(
            UTCDate.iso8601String(Date(timeIntervalSince1970: -1)) == "1969-12-31T23:59:59Z")
    }

    @Test("Formatting and parsing round-trip")
    func iso8601RoundTrips() throws {
        for offset in [0, 1, 86_399, 86_400, 1_800_000_000, -1, -86_401] {
            let date = Date(timeIntervalSince1970: Double(offset))
            let parsed = try #require(UTCDate.date(fromISO8601: UTCDate.iso8601String(date)))
            #expect(parsed == date)
        }
    }

    @Test(
        "Parsing accepts the variations a hand-written client or another encoder produces",
        arguments: [
            "2026-08-24T10:00:00Z",
            "2026-08-24T10:00:00z",
            "2026-08-24 10:00:00Z",  // a space instead of T, per RFC 3339's relaxed form
            "2026-08-24T10:00:00.000Z",
            "2026-08-24T10:00:00.123456789Z",  // fractional digits are read and discarded
            "2026-08-24T12:00:00+02:00",
            "2026-08-24T12:00:00+0200",  // no colon in the offset
            "2026-08-24T08:00:00-02:00",
            "2026-08-24T10:00:00",  // no zone at all: assumed UTC
        ])
    func iso8601ParsingAcceptsVariants(input: String) throws {
        let parsed = try #require(UTCDate.date(fromISO8601: input))
        #expect(UTCDate.iso8601String(parsed) == "2026-08-24T10:00:00Z")
    }

    @Test(
        "Parsing rejects anything it cannot read, rather than guessing",
        arguments: [
            "",
            "2026-08-24",  // a date with no time is not a timestamp
            "24/08/2026 10:00:00",
            "2026-08-24T10:00",  // no seconds
            "2026-08-24T10:00:00Q",  // not a zone designator
            "2026-08-24T10:00:00Z ",  // trailing whitespace
            "2026-08-24T10:00:00Zextra",
            "2026-08-24T10:00:00.Z",  // a dot with no digits
            "2026-13-24T10:00:00Z",  // month out of range
            "2026-08-32T10:00:00Z",
            "2026-08-24T24:00:00Z",  // hour out of range
            "2026-08-24T10:61:00Z",
            "20260824T100000Z",  // basic format, which nothing here emits
            "not-a-date",
        ])
    func iso8601ParsingRejectsGarbage(input: String) {
        #expect(UTCDate.date(fromISO8601: input) == nil)
    }

    @Test("A leap second folds onto :59 rather than failing the whole response")
    func iso8601LeapSecond() throws {
        // No clock the framework reads emits one, but rejecting it would throw away an otherwise
        // valid bootstrap response over a value that is legal ISO 8601.
        let parsed = try #require(UTCDate.date(fromISO8601: "2016-12-31T23:59:60Z"))
        #expect(UTCDate.iso8601String(parsed) == "2016-12-31T23:59:59Z")
    }

    @Test("padded pads and truncates nothing")
    func paddingBehaviour() {
        #expect(UTCDate.padded(7, 2) == "07")
        #expect(UTCDate.padded(0, 4) == "0000")
        #expect(UTCDate.padded(2026, 4) == "2026")
        // Wider than the field rather than truncated: a year 12026 stamp that read "2026" would
        // collide with a real one.
        #expect(UTCDate.padded(12_026, 4) == "12026")
        #expect(UTCDate.padded(-5, 3) == "-005")
    }
}

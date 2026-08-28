#if canImport(FoundationEssentials)
public import FoundationEssentials
#else
public import Foundation
#endif

/// UTC civil-date arithmetic and ISO 8601 formatting, built from epoch integers alone.
///
/// Deliberately uses neither `Calendar` nor any `FormatStyle`:
/// - `Calendar` and `TimeZone` are absent from `FoundationEssentials`, which is what the
///   server links on Linux, and this file is duplicated there verbatim.
/// - `Date.ISO8601FormatStyle` exists on Apple platforms and Linux but is not something
///   Skip's Kotlin transpiler can be relied on to handle, and this target has to transpile
///   (see README.md in this directory).
///
/// Ten lines of integer arithmetic removes both questions. The algorithms are Howard
/// Hinnant's `civil_from_days` / `days_from_civil`, which are exact for the proleptic
/// Gregorian calendar over any range `Int` can hold.
///
/// Everything here is UTC. Telemetry deduplication uses UTC rather than local time so that a
/// device crossing a timezone cannot skip or double a day
/// (`docs/adr/0004-client-side-dedup-no-identifier.md`).
public enum UTCDate {
    static let secondsPerDay = 86_400

    // MARK: - Civil date

    /// Year, month (1-12) and day (1-31) of `date` in UTC.
    public static func components(of date: Date) -> (year: Int, month: Int, day: Int) {
        civil(fromDaysSinceEpoch: daysSinceEpoch(date))
    }

    /// Whole days since 1970-01-01, flooring so pre-epoch dates round the right way.
    static func daysSinceEpoch(_ date: Date) -> Int {
        Int((date.timeIntervalSince1970 / Double(secondsPerDay)).rounded(.down))
    }

    /// Hinnant's `civil_from_days`.
    static func civil(fromDaysSinceEpoch days: Int) -> (year: Int, month: Int, day: Int) {
        var z = days
        z += 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097  // [0, 146096]
        let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365  // [0, 399]
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)  // [0, 365]
        let mp = (5 * doy + 2) / 153  // [0, 11]
        let d = doy - (153 * mp + 2) / 5 + 1  // [1, 31]
        let m = mp < 10 ? mp + 3 : mp - 9  // [1, 12]
        return (m <= 2 ? y + 1 : y, m, d)
    }

    /// Hinnant's `days_from_civil`, the inverse of `civil(fromDaysSinceEpoch:)`.
    static func daysSinceEpoch(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400  // [0, 399]
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1  // [0, 365]
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy  // [0, 146096]
        return era * 146_097 + doe - 719_468
    }

    /// Midnight UTC on the given civil date.
    public static func date(year: Int, month: Int, day: Int) -> Date {
        Date(
            timeIntervalSince1970: Double(daysSinceEpoch(year: year, month: month, day: day))
                * Double(secondsPerDay))
    }

    // MARK: - Stamps

    /// `2026-08-24` — the sort key of a daily counter, and the unit of `firstToday`.
    public static func dayStamp(_ date: Date) -> String {
        let c = components(of: date)
        return "\(padded(c.year, 4))-\(padded(c.month, 2))-\(padded(c.day, 2))"
    }

    /// `2026-08` — the sort key of a monthly counter, and the unit of `firstThisMonth`.
    public static func monthStamp(_ date: Date) -> String {
        let c = components(of: date)
        return "\(padded(c.year, 4))-\(padded(c.month, 2))"
    }

    /// Whether two instants fall on the same UTC day. Compared as day numbers rather than
    /// stamps: same answer, no string allocation on the launch path.
    public static func isSameDay(_ a: Date, _ b: Date) -> Bool {
        daysSinceEpoch(a) == daysSinceEpoch(b)
    }

    /// Whether two instants fall in the same UTC month.
    public static func isSameMonth(_ a: Date, _ b: Date) -> Bool {
        let x = components(of: a)
        let y = components(of: b)
        return x.year == y.year && x.month == y.month
    }

    /// Midnight UTC on the first of the month `count` whole months before `date`. Bounds the
    /// monthly query's sort key (`sk >= "2025-09"`).
    public static func monthsAgo(_ count: Int, from date: Date) -> Date {
        let c = components(of: date)
        // Months since year 0, so the arithmetic carries across a year boundary without a
        // special case. Kept non-negative by the calendar range we care about.
        let total = (c.year * 12 + (c.month - 1)) - count
        return self.date(year: total / 12, month: total % 12 + 1, day: 1)
    }

    /// Midnight UTC `count` whole days before `date`. Bounds the daily query.
    public static func daysAgo(_ count: Int, from date: Date) -> Date {
        let c = civil(fromDaysSinceEpoch: daysSinceEpoch(date) - count)
        return self.date(year: c.year, month: c.month, day: c.day)
    }

    /// Zero-padded decimal. `String(format:)` is not in `FoundationEssentials`.
    static func padded(_ value: Int, _ width: Int) -> String {
        let digits = String(value < 0 ? -value : value)
        let padding =
            digits.count >= width ? "" : String(repeating: "0", count: width - digits.count)
        return (value < 0 ? "-" : "") + padding + digits
    }

    // MARK: - ISO 8601

    /// `2026-08-24T10:00:00Z`, always UTC, always second precision.
    ///
    /// Second precision on purpose: the only timestamps Keel puts on the wire are
    /// `generatedAt` fields, where sub-second detail is noise that changes the bytes of every
    /// golden fixture.
    public static func iso8601String(_ date: Date) -> String {
        let total = Int(date.timeIntervalSince1970.rounded(.down))
        var dayNumber = total / secondsPerDay
        var secondOfDay = total % secondsPerDay
        if secondOfDay < 0 {  // Swift's `/` and `%` truncate toward zero; days must floor.
            secondOfDay += secondsPerDay
            dayNumber -= 1
        }
        let c = civil(fromDaysSinceEpoch: dayNumber)
        let hour = secondOfDay / 3_600
        let minute = (secondOfDay % 3_600) / 60
        let second = secondOfDay % 60
        return "\(padded(c.year, 4))-\(padded(c.month, 2))-\(padded(c.day, 2))"
            + "T\(padded(hour, 2)):\(padded(minute, 2)):\(padded(second, 2))Z"
    }

    /// Parses the subset of ISO 8601 Keel emits, plus the two variations a hand-written
    /// client or a different encoder is likely to produce: fractional seconds, and a numeric
    /// `+HH:MM` offset instead of `Z`.
    ///
    /// Returns nil rather than throwing, because every caller has a fallback and none of them
    /// wants a distinct error per malformed shape.
    public static func date(fromISO8601 string: String) -> Date? {
        // yyyy-MM-dd'T'HH:mm:ss, then an optional fraction, then a zone.
        let scalars = Array(string.utf8)
        func digits(_ range: Range<Int>) -> Int? {
            guard range.upperBound <= scalars.count else { return nil }
            var value = 0
            for index in range {
                let byte = scalars[index]
                guard byte >= 48, byte <= 57 else { return nil }
                value = value * 10 + Int(byte - 48)
            }
            return value
        }
        guard scalars.count >= 19,
            let year = digits(0..<4), scalars[4] == UInt8(ascii: "-"),
            let month = digits(5..<7), scalars[7] == UInt8(ascii: "-"),
            let day = digits(8..<10),
            scalars[10] == UInt8(ascii: "T") || scalars[10] == UInt8(ascii: " "),
            let hour = digits(11..<13), scalars[13] == UInt8(ascii: ":"),
            let minute = digits(14..<16), scalars[16] == UInt8(ascii: ":"),
            let second = digits(17..<19),
            month >= 1, month <= 12, day >= 1, day <= 31,
            hour <= 23, minute <= 59, second <= 60  // 60 for a leap second, clamped below.
        else { return nil }

        var index = 19
        if index < scalars.count, scalars[index] == UInt8(ascii: ".") {
            index += 1
            let start = index
            while index < scalars.count, scalars[index] >= 48, scalars[index] <= 57 { index += 1 }
            guard index > start else { return nil }  // A "." with no digits is malformed.
        }

        var offsetSeconds = 0
        if index < scalars.count {
            let zone = scalars[index]
            if zone == UInt8(ascii: "Z") || zone == UInt8(ascii: "z") {
                index += 1
            } else if zone == UInt8(ascii: "+") || zone == UInt8(ascii: "-") {
                guard let offsetHour = digits((index + 1)..<(index + 3)) else { return nil }
                var cursor = index + 3
                if cursor < scalars.count, scalars[cursor] == UInt8(ascii: ":") { cursor += 1 }
                let offsetMinute = digits(cursor..<(cursor + 2)) ?? 0
                if digits(cursor..<(cursor + 2)) != nil { cursor += 2 }
                offsetSeconds =
                    (offsetHour * 3_600 + offsetMinute * 60)
                    * (zone == UInt8(ascii: "-") ? -1 : 1)
                index = cursor
            } else {
                return nil
            }
        }
        guard index == scalars.count else { return nil }  // Trailing junk is malformed.

        let days = daysSinceEpoch(year: year, month: month, day: day)
        // A leap second is folded onto :59 rather than rejected — no clock Keel reads emits
        // one, but a rejection here would drop an otherwise valid response.
        let secondOfDay = hour * 3_600 + minute * 60 + min(second, 59)
        return Date(
            timeIntervalSince1970: Double(days * secondsPerDay + secondOfDay - offsetSeconds))
    }
}

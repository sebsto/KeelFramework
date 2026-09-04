import Foundation
import Testing

@testable import KeelServer

/// The keys asserted here are **byte-compatible with the format existing telemetry backends
/// already store in production**. They are not free to change: a rename means a retrofitted app
/// loses its history, or worse, keeps writing to one partition while the stats page reads
/// another. Treat a failure in this suite as a question about the change, not about the test.
@Suite("Counter schema")
struct CounterSchemaTests {

    /// `2026-08-24T10:00:00Z`.
    static let now = UTCDate.date(year: 2026, month: 8, day: 24).addingTimeInterval(10 * 3_600)

    @Test("Lifetime totals live at their historical keys and never expire")
    func lifetimeKeys() {
        #expect(CounterSchema.installsPartitionKey == "AGG#INSTALLS")
        #expect(CounterSchema.conversionsPartitionKey == "AGG#CONVERSIONS")
        #expect(CounterSchema.totalSortKey == "TOTAL")
    }

    @Test("The config item is a single addressable row")
    func configKeys() {
        #expect(CounterSchema.configPartitionKey == "CONFIG#current")
        #expect(CounterSchema.configSortKey == "v1")
    }

    @Test("Daily and monthly partitions match the deployed format")
    func timeSeriesKeys() {
        #expect(CounterSchema.dauPartitionKey == "AGG#DAU")
        #expect(CounterSchema.mauPartitionKey == "AGG#MAU")
        #expect(CounterSchema.dau(state: .free) == "AGG#DAU#free")
        #expect(CounterSchema.dau(state: .trial) == "AGG#DAU#trial")
        #expect(CounterSchema.dau(state: .paid) == "AGG#DAU#paid")
        #expect(CounterSchema.mau(state: .free) == "AGG#MAU#free")
        #expect(CounterSchema.mau(state: .paid) == "AGG#MAU#paid")
    }

    @Test("A cohort partition exists for every license state, with no collisions")
    func everyStateHasItsOwnPartition() {
        // A new `LicenseState` case with no partition would silently drop that cohort's counts,
        // so this walks the enum rather than listing the cases.
        let daily = Set(LicenseState.allCases.map { CounterSchema.dau(state: $0) })
        let monthly = Set(LicenseState.allCases.map { CounterSchema.mau(state: $0) })
        #expect(daily.count == LicenseState.allCases.count)
        #expect(monthly.count == LicenseState.allCases.count)
        #expect(daily.isDisjoint(with: monthly))
        // And none of them collides with the uncohorted total.
        #expect(!daily.contains(CounterSchema.dauPartitionKey))
        #expect(!monthly.contains(CounterSchema.mauPartitionKey))
    }

    @Test("Distributions put the month in the partition key and the value in the sort key")
    func distributionKeys() {
        // The month has to be in the *partition* here: a distribution's cardinality grows without
        // bound over time but is bounded within a month, and monthly partitions are what keep a
        // single Query from growing forever.
        #expect(CounterSchema.versions(month: Self.now) == "AGG#VER#2026-08")
        #expect(CounterSchema.osVersions(month: Self.now) == "AGG#OS#2026-08")
        #expect(CounterSchema.platforms(month: Self.now) == "AGG#PLAT#2026-08")
        #expect(
            CounterSchema.dimension(name: "profiles", month: Self.now)
                == "AGG#DIM#profiles#2026-08")
    }

    @Test("Sort keys are the padded UTC stamps")
    func sortKeys() {
        #expect(CounterSchema.daySortKey(Self.now) == "2026-08-24")
        #expect(CounterSchema.monthSortKey(Self.now) == "2026-08")
        // Local time is never involved: a device flying east must not skip a day or count two.
        let lateUTC = UTCDate.date(year: 2026, month: 8, day: 24).addingTimeInterval(23 * 3_600)
        #expect(CounterSchema.daySortKey(lateUTC) == "2026-08-24")
    }

    @Test("Every dimension name gets its own partition, per month")
    func dimensionsDoNotCollide() {
        let profiles = CounterSchema.dimension(name: "profiles", month: Self.now)
        let servers = CounterSchema.dimension(name: "servers", month: Self.now)
        let lastMonth = CounterSchema.dimension(
            name: "profiles", month: UTCDate.monthsAgo(1, from: Self.now))
        #expect(profiles != servers)
        #expect(profiles != lastMonth)
        #expect(lastMonth == "AGG#DIM#profiles#2026-07")
    }

    // MARK: - Expiry

    @Test("Expiry is epoch seconds, 400 days out")
    func expiryIsSeconds() {
        let expiry = CounterSchema.expiry(from: Self.now)
        #expect(expiry == Int(Self.now.timeIntervalSince1970) + 400 * 86_400)
        // Seconds, not milliseconds: DynamoDB accepts a millisecond value without complaint and
        // then expires the item in the year 56000, which surfaces as "the table never shrinks".
        #expect(expiry < 4_000_000_000)
        #expect(UTCDate.dayStamp(Date(timeIntervalSince1970: Double(expiry))) == "2027-09-28")
    }

    @Test("The retention window is longer than a year, so year-over-year has something to compare")
    func retentionExceedsAYear() {
        #expect(Keel.counterTTLDays > 365)
        #expect(Keel.counterTTLDays == 400)
    }

    // MARK: - Query windows

    @Test("A day window includes today and the days before it, with no off-by-one")
    func dayWindowBounds() {
        // 30 days ending today spans today and the 29 before it. Getting this wrong makes the
        // first column of every chart a day short, which nobody notices for months.
        #expect(CounterSchema.dayWindowStart(days: 30, endingAt: Self.now) == "2026-07-26")
        #expect(CounterSchema.dayWindowStart(days: 1, endingAt: Self.now) == "2026-08-24")
        #expect(CounterSchema.dayWindowStart(days: 0, endingAt: Self.now) == "2026-08-24")
    }

    @Test("A month window includes the current, partial month")
    func monthWindowBounds() {
        #expect(CounterSchema.monthWindowStart(months: 12, endingAt: Self.now) == "2025-09")
        #expect(CounterSchema.monthWindowStart(months: 1, endingAt: Self.now) == "2026-08")
    }

    @Test("Stamp skeletons are contiguous, oldest first, and match the window bound")
    func stampSkeletons() {
        let days = CounterSchema.dayStamps(days: 5, endingAt: Self.now)
        #expect(days == ["2026-08-20", "2026-08-21", "2026-08-22", "2026-08-23", "2026-08-24"])
        #expect(days.first == CounterSchema.dayWindowStart(days: 5, endingAt: Self.now))
        #expect(days.last == CounterSchema.daySortKey(Self.now))

        let months = CounterSchema.monthStamps(months: 3, endingAt: Self.now)
        #expect(months == ["2026-06", "2026-07", "2026-08"])
        #expect(months.first == CounterSchema.monthWindowStart(months: 3, endingAt: Self.now))

        #expect(CounterSchema.dayStamps(days: 0, endingAt: Self.now).isEmpty)
        #expect(CounterSchema.monthStamps(months: 0, endingAt: Self.now).isEmpty)
    }

    @Test("A window crossing a year boundary stays contiguous")
    func skeletonsCrossYears() {
        let newYear = UTCDate.date(year: 2026, month: 1, day: 2)
        #expect(
            CounterSchema.dayStamps(days: 4, endingAt: newYear)
                == ["2025-12-30", "2025-12-31", "2026-01-01", "2026-01-02"])
        #expect(
            CounterSchema.monthStamps(months: 3, endingAt: newYear)
                == ["2025-11", "2025-12", "2026-01"])
    }

    @Test("A skeleton is exactly as long as its window")
    func skeletonLengths() {
        for length in [1, 7, 30, 90, 400] {
            #expect(CounterSchema.dayStamps(days: length, endingAt: Self.now).count == length)
        }
        for length in [1, 2, 12, 24] {
            #expect(CounterSchema.monthStamps(months: length, endingAt: Self.now).count == length)
        }
    }

    @Test("Nothing in the schema requires a Scan or a secondary index")
    func everyKeyIsDirectlyAddressable() {
        // Every partition name is derivable from a request or a clock, which is what makes the
        // read path Query-only. A key that needed discovery would need a GSI, and a GSI on a
        // counter table is a second copy of every write.
        let partitions =
            [
                CounterSchema.configPartitionKey,
                CounterSchema.installsPartitionKey,
                CounterSchema.conversionsPartitionKey,
                CounterSchema.dauPartitionKey,
                CounterSchema.mauPartitionKey,
                CounterSchema.versions(month: Self.now),
                CounterSchema.osVersions(month: Self.now),
                CounterSchema.platforms(month: Self.now),
                CounterSchema.dimension(name: "profiles", month: Self.now),
            ]
            + LicenseState.allCases.flatMap {
                [CounterSchema.dau(state: $0), CounterSchema.mau(state: $0)]
            }
        #expect(Set(partitions).count == partitions.count)
        // Aggregates are namespaced away from configuration so no query can reach both.
        for partition in partitions where partition != CounterSchema.configPartitionKey {
            #expect(partition.hasPrefix("AGG#"))
        }
    }
}

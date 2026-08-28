public import Logging

#if canImport(FoundationEssentials)
public import FoundationEssentials
#else
public import Foundation
#endif

/// `GET /v1/stats` — publish every aggregate the table holds.
///
/// Completeness is the mechanism behind the privacy claim, not a feature: anybody can fetch this
/// and see that the backend stores counters and nothing else (`docs/ARCHITECTURE.md` §9). A counter
/// added to the table without a field here breaks that, which is why `KeelServerTests` asserts the
/// published key set covers every partition `CounterSchema` writes.
///
/// **This one propagates store failures**, unlike bootstrap and ping. The reasoning is the
/// opposite in each case: a failed bootstrap breaks every launching app, and a failed ping teaches
/// a client to retry a non-idempotent write — but a stats page that renders partial numbers as if
/// they were complete is worse than one that says it could not load. It is edge-cached, nobody's
/// launch depends on it, and a refresh is free.
public struct StatsHandler: Sendable {
    let store: any CounterStore
    let cache: ConfigCache

    /// Trailing days of DAU, including today. 30 by default — a month of context is what the chart
    /// is for, and 400 days of history exists for anyone who wants to widen it.
    let dauWindowDays: Int

    /// Trailing months of MAU, including the current partial one.
    let mauWindowMonths: Int

    let clock: @Sendable () -> Date
    let logger: Logger

    public init(
        store: any CounterStore,
        cache: ConfigCache,
        dauWindowDays: Int = 30,
        mauWindowMonths: Int = 12,
        clock: @escaping @Sendable () -> Date = { Date() },
        logger: Logger = Logger(label: "keel.stats")
    ) {
        self.store = store
        self.cache = cache
        self.dauWindowDays = dauWindowDays
        self.mauWindowMonths = mauWindowMonths
        self.clock = clock
        self.logger = logger
    }

    /// Assemble the response from 13 concurrent Queries, plus one per declared dimension.
    ///
    /// Every one is a `Query` on a single partition key, never a `Scan`. They are independent, so
    /// they are issued together: reading thirteen partitions serially would put thirteen round
    /// trips on an endpoint whose entire body is those thirteen reads, and the count grows with
    /// every series the framework learns.
    public func handle() async throws -> StatsResponse {
        let now = clock()
        let config = await cache.current()
        let dayFrom = CounterSchema.dayWindowStart(days: dauWindowDays, endingAt: now)
        let monthFrom = CounterSchema.monthWindowStart(months: mauWindowMonths, endingAt: now)

        async let installs = store.total(
            partitionKey: CounterSchema.installsPartitionKey, sortKey: CounterSchema.totalSortKey)
        async let conversions = store.total(
            partitionKey: CounterSchema.conversionsPartitionKey,
            sortKey: CounterSchema.totalSortKey)
        async let dauRows = store.query(
            partitionKey: CounterSchema.dauPartitionKey, sortKeyFrom: dayFrom)
        async let mauRows = store.query(
            partitionKey: CounterSchema.mauPartitionKey, sortKeyFrom: monthFrom)
        async let versionRows = store.query(
            partitionKey: CounterSchema.versions(month: now), sortKeyFrom: nil)
        async let osRows = store.query(
            partitionKey: CounterSchema.osVersions(month: now), sortKeyFrom: nil)
        async let platformRows = store.query(
            partitionKey: CounterSchema.platforms(month: now), sortKeyFrom: nil)
        async let dauCohorts = cohorts(from: dayFrom, partition: CounterSchema.dau(state:))
        async let mauCohorts = cohorts(from: monthFrom, partition: CounterSchema.mau(state:))
        async let dimensions = dimensionShares(config.telemetry.dimensions, month: now)

        let days = CounterSchema.dayStamps(days: dauWindowDays, endingAt: now)
        let months = CounterSchema.monthStamps(months: mauWindowMonths, endingAt: now)

        let dauByDay = Self.counts(try await dauRows)
        let mauByMonth = Self.counts(try await mauRows)
        let dauCohortCounts = try await dauCohorts
        let mauCohortCounts = try await mauCohorts

        return StatsResponse(
            generatedAt: now,
            installs: try await installs,
            conversions: try await conversions,
            // The calendar is authoritative, not the query result: a day with no pings is a `0`
            // the chart needs, and a row outside the window (a clock skewed forward, say) is not
            // drawn at all rather than stretching the axis.
            dau: days.map { StatsResponse.DailyPoint(date: $0, count: dauByDay[$0] ?? 0) },
            dauByState: days.map { day in
                StatsResponse.DailyCohortPoint(
                    date: day,
                    free: dauCohortCounts[.free]?[day] ?? 0,
                    trial: dauCohortCounts[.trial]?[day] ?? 0,
                    paid: dauCohortCounts[.paid]?[day] ?? 0)
            },
            mau: months.map { StatsResponse.MonthlyPoint(month: $0, count: mauByMonth[$0] ?? 0) },
            mauByState: months.map { month in
                StatsResponse.MonthlyCohortPoint(
                    month: month,
                    free: mauCohortCounts[.free]?[month] ?? 0,
                    trial: mauCohortCounts[.trial]?[month] ?? 0,
                    paid: mauCohortCounts[.paid]?[month] ?? 0)
            },
            versions: Self.ranked(try await versionRows).map {
                StatsResponse.VersionShare(version: $0.sortKey, count: $0.count)
            },
            osVersions: Self.ranked(try await osRows).map {
                StatsResponse.OSShare(osVersion: $0.sortKey, count: $0.count)
            },
            platforms: Self.ranked(try await platformRows).map {
                StatsResponse.PlatformShare(platform: $0.sortKey, count: $0.count)
            },
            dimensions: try await dimensions)
    }

    // MARK: - Reads

    /// One partition per license state, read concurrently, as `[state: [stamp: count]]`.
    ///
    /// Driven by `LicenseState.allCases` rather than three hardcoded queries. That is not
    /// stylistic: `trial` was added to this framework after the cohorts were first written, and
    /// every hand-listed site had to be found. A new state now reaches the response by construction.
    private func cohorts(
        from sortKeyFrom: String,
        partition: @Sendable (LicenseState) -> String
    ) async throws -> [LicenseState: [String: Int]] {
        // Resolved before the group so the closure captures strings rather than the function —
        // `addTask` escapes, and the naming function does not need to.
        let partitions = LicenseState.allCases.map { (state: $0, partitionKey: partition($0)) }
        return try await withThrowingTaskGroup(of: (LicenseState, [CounterRow]).self) { group in
            for (state, partitionKey) in partitions {
                group.addTask {
                    let rows = try await store.query(
                        partitionKey: partitionKey, sortKeyFrom: sortKeyFrom)
                    return (state, rows)
                }
            }
            var result: [LicenseState: [String: Int]] = [:]
            for try await (state, rows) in group {
                result[state] = Self.counts(rows)
            }
            return result
        }
    }

    /// One partition per declared dimension, read concurrently.
    ///
    /// Buckets come back in the order the config declares, *not* by count: `1-2, 3-5, 6-10, 11+`
    /// sorted by frequency is a distribution with its axis shuffled. A bucket never observed is
    /// omitted rather than zero-filled — unlike a missing day, an unobserved bucket is genuinely
    /// unmeasured, and only the config knows which ones were supposed to exist.
    private func dimensionShares(
        _ declared: [DimensionConfig], month: Date
    ) async throws -> [String: [StatsResponse.BucketShare]] {
        guard !declared.isEmpty else { return [:] }
        return try await withThrowingTaskGroup(
            of: (String, [StatsResponse.BucketShare]).self
        ) { group in
            for dimension in declared {
                group.addTask {
                    let rows = try await store.query(
                        partitionKey: CounterSchema.dimension(name: dimension.name, month: month),
                        sortKeyFrom: nil)
                    let counts = Self.counts(rows)
                    let shares = dimension.buckets.compactMap { bucket in
                        counts[bucket].map {
                            StatsResponse.BucketShare(bucket: bucket, count: $0)
                        }
                    }
                    return (dimension.name, shares)
                }
            }
            var result: [String: [StatsResponse.BucketShare]] = [:]
            for try await (name, shares) in group {
                result[name] = shares
            }
            return result
        }
    }

    // MARK: - Shaping

    /// Rows as a lookup. A duplicated sort key cannot come out of one DynamoDB partition, so the
    /// last-one-wins rule only ever applies to a hand-built fake.
    private static func counts(_ rows: [CounterRow]) -> [String: Int] {
        Dictionary(rows.map { ($0.sortKey, $0.count) }, uniquingKeysWith: { $1 })
    }

    /// Descending by count, then ascending by key.
    ///
    /// The tie-break is not cosmetic: without it two versions with equal counts swap places
    /// between requests, which makes the chart flicker across a cache boundary and makes any test
    /// that asserts an order intermittently wrong.
    private static func ranked(_ rows: [CounterRow]) -> [CounterRow] {
        rows.sorted {
            $0.count == $1.count ? $0.sortKey < $1.sortKey : $0.count > $1.count
        }
    }
}

import Foundation
import KeelServerTesting
import Testing

@testable import KeelServer

/// The published page is the privacy claim's evidence, so the assertions here are mostly about
/// *completeness and shape*: every series present, every window fully drawn, every order stable.
/// The read count is asserted too — it is the cost model in §11, and it is invisible otherwise.
@Suite("Stats handler")
struct StatsHandlerTests {

    static let now = TestClock.default  // 2026-08-24T10:00:00Z
    static let month = "2026-08"

    static let profiles = DimensionConfig(name: "profiles", buckets: ["1-2", "3-5", "6-10", "11+"])
    static let theme = DimensionConfig(name: "theme", buckets: ["light", "dark"])

    private static func handler(
        store: InMemoryCounterStore,
        config: RemoteConfig = .empty,
        dauWindowDays: Int = 30,
        mauWindowMonths: Int = 12
    ) -> StatsHandler {
        StatsHandler(
            store: store,
            cache: ConfigCache(
                store: InMemoryConfigStore(config), ttl: 3_600, clock: { Self.now }),
            dauWindowDays: dauWindowDays,
            mauWindowMonths: mauWindowMonths,
            clock: { Self.now })
    }

    // MARK: - Totals

    @Test("The lifetime totals are read from their TOTAL rows")
    func lifetimeTotals() async throws {
        let store = InMemoryCounterStore()
        store.seed(partitionKey: "AGG#INSTALLS", sortKey: "TOTAL", count: 41_207)
        store.seed(partitionKey: "AGG#CONVERSIONS", sortKey: "TOTAL", count: 1_884)

        let response = try await Self.handler(store: store).handle()
        #expect(response.installs == 41_207)
        #expect(response.conversions == 1_884)
    }

    @Test("An empty table publishes a complete page of zeroes")
    func emptyTable() async throws {
        let response = try await Self.handler(store: InMemoryCounterStore(), dauWindowDays: 3)
            .handle()
        // A fresh stack is the normal state for a while, and a dashboard needs to tell "no data"
        // from "this build has no such series" — which a missing key cannot say.
        #expect(response.installs == 0)
        #expect(response.conversions == 0)
        #expect(response.dau.count == 3)
        #expect(response.dau.allSatisfy { $0.count == 0 })
        #expect(response.dauByState.count == 3)
        #expect(response.versions.isEmpty)
        #expect(response.dimensions.isEmpty)
    }

    // MARK: - Windows and zero-fill

    @Test("The window is drawn from the calendar, oldest first, with gaps as zeroes")
    func zeroFillsFromTheCalendar() async throws {
        let store = InMemoryCounterStore()
        store.seed("AGG#DAU", ["2026-08-22": 611, "2026-08-24": 640])

        let response = try await Self.handler(store: store, dauWindowDays: 5).handle()

        // Five days ending today, inclusive: the off-by-one that makes a chart's first column a
        // day short. And a day with no pings is a `0` the chart needs, not a gap it must interpret.
        #expect(
            response.dau == [
                StatsResponse.DailyPoint(date: "2026-08-20", count: 0),
                StatsResponse.DailyPoint(date: "2026-08-21", count: 0),
                StatsResponse.DailyPoint(date: "2026-08-22", count: 611),
                StatsResponse.DailyPoint(date: "2026-08-23", count: 0),
                StatsResponse.DailyPoint(date: "2026-08-24", count: 640),
            ])
    }

    @Test("Months are drawn the same way, ending with the current partial month")
    func monthlyWindow() async throws {
        let store = InMemoryCounterStore()
        store.seed("AGG#MAU", ["2026-07": 9_004, "2026-08": 7_112])

        let response = try await Self.handler(store: store, mauWindowMonths: 3).handle()
        #expect(
            response.mau == [
                StatsResponse.MonthlyPoint(month: "2026-06", count: 0),
                StatsResponse.MonthlyPoint(month: "2026-07", count: 9_004),
                StatsResponse.MonthlyPoint(month: "2026-08", count: 7_112),
            ])
    }

    @Test("A row outside the window is not drawn")
    func rowsOutsideTheWindowAreDropped() async throws {
        let store = InMemoryCounterStore()
        store.seed("AGG#DAU", ["2026-08-23": 5, "2026-09-01": 999])

        let response = try await Self.handler(store: store, dauWindowDays: 3).handle()

        // A clock skewed forward on one device writes tomorrow's counter. Letting it through would
        // stretch the axis past today and put a single install's row beside a real day's total.
        #expect(response.dau.map(\.date) == ["2026-08-22", "2026-08-23", "2026-08-24"])
        #expect(!response.dau.contains { $0.count == 999 })
    }

    @Test("The daily query is bounded by the window's first day")
    func queryIsBounded() async throws {
        let store = InMemoryCounterStore()
        _ = try await Self.handler(store: store, dauWindowDays: 30, mauWindowMonths: 12).handle()

        // The bound is what makes a 30-day window cost one request against a partition holding 400
        // days. Reading the whole partition would work and would get slowly more expensive forever.
        #expect(
            store.queries.contains(
                InMemoryCounterStore.Query(partitionKey: "AGG#DAU", sortKeyFrom: "2026-07-26")))
        #expect(
            store.queries.contains(
                InMemoryCounterStore.Query(partitionKey: "AGG#MAU", sortKeyFrom: "2025-09")))
        // A monthly distribution is bounded by construction, so it is read whole.
        #expect(
            store.queries.contains(
                InMemoryCounterStore.Query(
                    partitionKey: "AGG#VER#\(Self.month)", sortKeyFrom: nil)))
    }

    // MARK: - Cohorts

    @Test("Every license state is read, and each cohort series covers the whole window")
    func cohorts() async throws {
        let store = InMemoryCounterStore()
        store.seed("AGG#DAU#free", ["2026-08-24": 500])
        store.seed("AGG#DAU#trial", ["2026-08-24": 40])
        store.seed("AGG#DAU#paid", ["2026-08-23": 90, "2026-08-24": 100])

        let response = try await Self.handler(store: store, dauWindowDays: 2).handle()

        #expect(
            response.dauByState == [
                StatsResponse.DailyCohortPoint(date: "2026-08-23", free: 0, trial: 0, paid: 90),
                StatsResponse.DailyCohortPoint(date: "2026-08-24", free: 500, trial: 40, paid: 100),
            ])
    }

    @Test("Monthly cohorts are read from their own partitions")
    func monthlyCohorts() async throws {
        let store = InMemoryCounterStore()
        store.seed("AGG#MAU#paid", ["2026-08": 1_800])

        let response = try await Self.handler(store: store, mauWindowMonths: 1).handle()
        #expect(
            response.mauByState == [
                StatsResponse.MonthlyCohortPoint(month: "2026-08", free: 0, trial: 0, paid: 1_800)
            ])
    }

    @Test("A license state added to the enum is read without touching the handler")
    func cohortsCoverEveryState() async throws {
        let store = InMemoryCounterStore()
        _ = try await Self.handler(store: store).handle()

        // `trial` was added after the cohorts were first written and every hand-listed site had to
        // be found. Driving the fan-out from `allCases` is what stops that recurring.
        for state in LicenseState.allCases {
            #expect(store.queries.contains { $0.partitionKey == "AGG#DAU#\(state.rawValue)" })
            #expect(store.queries.contains { $0.partitionKey == "AGG#MAU#\(state.rawValue)" })
        }
    }

    // MARK: - Distributions

    @Test("Versions, OS versions and platforms come back ranked by count")
    func distributionsAreRanked() async throws {
        let store = InMemoryCounterStore()
        store.seed("AGG#VER#\(Self.month)", ["1.9.0": 9, "2.1.0": 5, "2.0.0": 5])
        store.seed("AGG#OS#\(Self.month)", ["26.1": 800, "25.6": 120])
        store.seed("AGG#PLAT#\(Self.month)", ["ios": 700, "macos": 220])

        let response = try await Self.handler(store: store).handle()

        // Descending by count, then *ascending by key*. Without the tie-break two equal counts swap
        // places between requests, which makes the chart flicker across a cache boundary.
        #expect(response.versions.map(\.version) == ["1.9.0", "2.0.0", "2.1.0"])
        #expect(response.versions.map(\.count) == [9, 5, 5])
        #expect(response.osVersions.map(\.osVersion) == ["26.1", "25.6"])
        #expect(response.platforms.map(\.platform) == ["ios", "macos"])
    }

    @Test("Distributions are read from the current month's partition")
    func distributionsAreThisMonth() async throws {
        let store = InMemoryCounterStore()
        store.seed("AGG#VER#2026-07", ["1.0.0": 400])
        store.seed("AGG#VER#2026-08", ["2.1.0": 12])

        let response = try await Self.handler(store: store).handle()
        // "Which versions are in use" is a question about now. Last month's spread is still in the
        // table and still readable by widening the window on purpose, not by accident.
        #expect(response.versions == [StatsResponse.VersionShare(version: "2.1.0", count: 12)])
    }

    @Test("A platform value the enum does not know is published rather than dropped")
    func unknownPlatformSurvives() async throws {
        let store = InMemoryCounterStore()
        store.seed("AGG#PLAT#\(Self.month)", ["ios": 10, "carplay": 3])

        let response = try await Self.handler(store: store).handle()
        // Written by a newer build of the server, read by an older one after a rollback. Rejecting
        // it would 500 the whole page over a partition nobody needs to understand.
        #expect(response.platforms.map(\.platform) == ["ios", "carplay"])
    }

    // MARK: - Dimensions

    @Test("Buckets are published in the order the config declares")
    func dimensionsFollowDeclaredOrder() async throws {
        let store = InMemoryCounterStore()
        store.seed("AGG#DIM#profiles#\(Self.month)", ["11+": 90, "1-2": 400, "3-5": 250])
        let handler = Self.handler(
            store: store,
            config: RemoteConfig(
                telemetry: TelemetrySettings(dimensions: [
                    Self.profiles
                ])))

        let response = try await handler.handle()

        // Not by count, unlike the three series above: `1-2, 3-5, 6-10, 11+` sorted by frequency is
        // a distribution with its axis shuffled. `6-10` was never observed, so it is omitted —
        // unmeasured is not zero, and unlike a missing day only the config knows it should exist.
        #expect(
            response.dimensions["profiles"] == [
                StatsResponse.BucketShare(bucket: "1-2", count: 400),
                StatsResponse.BucketShare(bucket: "3-5", count: 250),
                StatsResponse.BucketShare(bucket: "11+", count: 90),
            ])
    }

    @Test("A declared dimension with no data is an empty series, not a missing key")
    func declaredButUnobservedDimension() async throws {
        let handler = Self.handler(
            store: InMemoryCounterStore(),
            config: RemoteConfig(telemetry: TelemetrySettings(dimensions: [Self.theme])))
        let response = try await handler.handle()
        #expect(response.dimensions["theme"] == [])
    }

    @Test("A bucket in the table that the config no longer declares is not published")
    func undeclaredBucketIsNotPublished() async throws {
        let store = InMemoryCounterStore()
        store.seed("AGG#DIM#profiles#\(Self.month)", ["1-2": 10, "42": 7])
        let handler = Self.handler(
            store: store,
            config: RemoteConfig(telemetry: TelemetrySettings(dimensions: [Self.profiles])))

        let response = try await handler.handle()
        // History written under a bucket label that has since been renamed stays in the table and
        // stops being drawn. The config is the axis, in both directions.
        #expect(response.dimensions["profiles"]?.map(\.bucket) == ["1-2"])
    }

    @Test("A dimension the config does not declare is not read at all")
    func undeclaredDimensionIsNotRead() async throws {
        let store = InMemoryCounterStore()
        store.seed("AGG#DIM#profiles#\(Self.month)", ["1-2": 10])

        let response = try await Self.handler(store: store).handle()
        #expect(response.dimensions.isEmpty)
        #expect(!store.queries.contains { $0.partitionKey.hasPrefix("AGG#DIM#") })
    }

    // MARK: - Cost

    @Test("The page costs thirteen reads plus one per declared dimension")
    func readCount() async throws {
        let store = InMemoryCounterStore()
        _ = try await Self.handler(store: store).handle()
        // 2 totals + DAU + MAU + 3 distributions + 3 DAU cohorts + 3 MAU cohorts. §11's cost model
        // is stated in these terms, and this is the only thing that keeps it true.
        #expect(store.queries.count == 13)

        let withDimensions = InMemoryCounterStore()
        _ = try await Self.handler(
            store: withDimensions,
            config: RemoteConfig(
                telemetry: TelemetrySettings(dimensions: [Self.profiles, Self.theme]))
        ).handle()
        #expect(withDimensions.queries.count == 15)
    }

    @Test("No partition is read twice")
    func readsAreDistinct() async throws {
        let store = InMemoryCounterStore()
        _ = try await Self.handler(
            store: store,
            config: RemoteConfig(telemetry: TelemetrySettings(dimensions: [Self.profiles]))
        ).handle()
        // Two `async let`s on the same partition would be a wasted RCU on every request, and the
        // kind of duplication that hides in a wall of `async let`s.
        #expect(Set(store.queries.map(\.partitionKey)).count == store.queries.count)
    }

    // MARK: - Failure

    @Test("A read failure fails the whole page")
    func readFailurePropagates() async {
        let store = InMemoryCounterStore()
        store.seed(partitionKey: "AGG#INSTALLS", sortKey: "TOTAL", count: 41_207)
        store.failReads(of: "AGG#DAU")

        // The opposite call from bootstrap and ping, deliberately: a page that renders partial
        // numbers as if they were complete is worse than one that says it could not load. It is
        // edge-cached, nobody's launch depends on it, and a refresh is free.
        await #expect(throws: InMemoryCounterStore.ReadFailure.self) {
            _ = try await Self.handler(store: store).handle()
        }
    }

    @Test("A failing cohort partition fails the page too")
    func cohortFailurePropagates() async {
        let store = InMemoryCounterStore()
        store.failReads(of: "AGG#DAU#trial")
        await #expect(throws: InMemoryCounterStore.ReadFailure.self) {
            _ = try await Self.handler(store: store).handle()
        }
    }

    @Test("A failing dimension partition fails the page too")
    func dimensionFailurePropagates() async {
        let store = InMemoryCounterStore()
        store.failReads(of: "AGG#DIM#profiles#\(Self.month)")
        await #expect(throws: InMemoryCounterStore.ReadFailure.self) {
            _ = try await Self.handler(
                store: store,
                config: RemoteConfig(telemetry: TelemetrySettings(dimensions: [Self.profiles]))
            ).handle()
        }
    }

    @Test("An unreadable config still publishes every counter series")
    func unreadableConfigStillPublishes() async throws {
        let store = InMemoryCounterStore()
        store.seed("AGG#DAU", ["2026-08-24": 640])
        let configStore = InMemoryConfigStore(nil)
        configStore.failLoads()
        let handler = StatsHandler(
            store: store,
            cache: ConfigCache(store: configStore, ttl: 60, clock: { Self.now }),
            dauWindowDays: 1,
            clock: { Self.now })

        // The config only contributes the dimension list. Losing it costs the app-declared charts,
        // not the page — the counters are what the privacy claim is about.
        let response = try await handler.handle()
        #expect(response.dau == [StatsResponse.DailyPoint(date: "2026-08-24", count: 640)])
        #expect(response.dimensions.isEmpty)
    }

    // MARK: - Stamping

    @Test("The response is stamped with the time it was assembled")
    func stampsTheResponse() async throws {
        let response = try await Self.handler(store: InMemoryCounterStore()).handle()
        #expect(response.generatedAt == Self.now)
    }
}

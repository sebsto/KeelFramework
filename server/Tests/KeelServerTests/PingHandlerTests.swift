import Foundation
import InMemoryLogging
import KeelServerTesting
import Logging
import Testing

@testable import KeelServer

/// Two things are being tested and they are deliberately separable: `plan(for:at:accepting:)` is a
/// pure function from a request to a set of keys, and `handle` is the effects around it. The plan is
/// asserted directly rather than inferred from a fake's side effects, because the plan *is* the
/// design decision in that file — which boolean moves which counter, and how the two version rules
/// compose.
@Suite("Ping handler")
struct PingHandlerTests {

    static let now = TestClock.default
    static let day = "2026-08-24"
    static let month = "2026-08"

    static let profiles = DimensionConfig(name: "profiles", buckets: ["1-2", "3-5", "6-10", "11+"])
    static let theme = DimensionConfig(name: "theme", buckets: ["light", "dark"])
    static let telemetry = TelemetrySettings(dimensions: [profiles, theme])

    /// A request with every boolean off; each test turns on the one it is about.
    private static func request(
        firstPingEver: Bool = false,
        firstToday: Bool = false,
        firstThisMonth: Bool = false,
        firstThisVersion: Bool = false,
        firstPaidLaunch: Bool = false,
        appVersion: String = "2.1.0",
        osVersion: String = "26.1",
        platform: Platform = .iOS,
        licenseState: LicenseState = .free,
        dimensions: [String: String] = [:]
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

    private static func handler(
        store: InMemoryCounterStore,
        config: RemoteConfig = RemoteConfig(telemetry: telemetry),
        handler logHandler: InMemoryLogHandler = InMemoryLogHandler()
    ) -> PingHandler {
        PingHandler(
            store: store,
            cache: ConfigCache(
                store: InMemoryConfigStore(config), ttl: 3_600, clock: { Self.now },
                logger: logHandler.logger),
            clock: { Self.now },
            logger: logHandler.logger)
    }

    /// `(pk, sk)` pairs, which is what the assertions are actually about.
    private static func keys(_ writes: [CounterWrite]) -> [String] {
        writes.map { "\($0.partitionKey)/\($0.sortKey)" }
    }

    // MARK: - The plan

    @Test("A first-ever launch writes the install, the day, the month and every monthly spread")
    func firstEverLaunch() {
        let writes = PingHandler.plan(
            for: Self.request(
                firstPingEver: true, firstToday: true, firstThisMonth: true,
                firstThisVersion: true),
            at: Self.now,
            accepting: Self.telemetry)

        #expect(
            Self.keys(writes) == [
                "AGG#INSTALLS/TOTAL",
                "AGG#DAU/\(Self.day)",
                "AGG#DAU#free/\(Self.day)",
                "AGG#MAU/\(Self.month)",
                "AGG#MAU#free/\(Self.month)",
                "AGG#OS#\(Self.month)/26.1",
                "AGG#PLAT#\(Self.month)/ios",
                "AGG#VER#\(Self.month)/2.1.0",
            ])
    }

    @Test("A first launch of the day writes two counters and nothing monthly")
    func firstToday() {
        let writes = PingHandler.plan(
            for: Self.request(firstToday: true, licenseState: .paid),
            at: Self.now,
            accepting: Self.telemetry)
        #expect(Self.keys(writes) == ["AGG#DAU/\(Self.day)", "AGG#DAU#paid/\(Self.day)"])
    }

    @Test("Conversions are a lifetime total, counted once per install")
    func firstPaidLaunch() {
        let writes = PingHandler.plan(
            for: Self.request(firstPaidLaunch: true, licenseState: .paid),
            at: Self.now,
            accepting: Self.telemetry)
        #expect(Self.keys(writes) == ["AGG#CONVERSIONS/TOTAL"])
    }

    @Test("Lifetime totals carry no TTL; everything dated does")
    func expiryPolicy() {
        let writes = PingHandler.plan(
            for: Self.request(
                firstPingEver: true, firstToday: true, firstThisMonth: true,
                firstPaidLaunch: true),
            at: Self.now,
            accepting: Self.telemetry)

        let lifetime = writes.filter { $0.sortKey == CounterSchema.totalSortKey }
        #expect(lifetime.count == 2)
        // An absent attribute is unambiguous; a far-future date picked today eventually arrives.
        #expect(lifetime.allSatisfy { $0.ttl == nil })

        let dated = writes.filter { $0.sortKey != CounterSchema.totalSortKey }
        #expect(!dated.isEmpty)
        #expect(dated.allSatisfy { $0.ttl == CounterSchema.expiry(from: Self.now) })
    }

    @Test("OS, platform and dimension spreads are monthly, not daily")
    func spreadsAreMonthly() {
        // odvpn increments the OS spread on `firstToday`, which makes its total a sum of daily
        // actives — comparable to nothing else it publishes. Deduping monthly makes
        // `sum(osVersions) ≈ mau`: one observation per install per month, the same census MAU takes.
        let daily = PingHandler.plan(
            for: Self.request(firstToday: true, dimensions: ["profiles": "3-5"]),
            at: Self.now,
            accepting: Self.telemetry)
        #expect(!Self.keys(daily).contains { $0.hasPrefix("AGG#OS#") })
        #expect(!Self.keys(daily).contains { $0.hasPrefix("AGG#PLAT#") })
        #expect(!Self.keys(daily).contains { $0.hasPrefix("AGG#DIM#") })

        let monthly = PingHandler.plan(
            for: Self.request(firstThisMonth: true, dimensions: ["profiles": "3-5"]),
            at: Self.now,
            accepting: Self.telemetry)
        #expect(Self.keys(monthly).contains("AGG#OS#\(Self.month)/26.1"))
        #expect(Self.keys(monthly).contains("AGG#PLAT#\(Self.month)/ios"))
        #expect(Self.keys(monthly).contains("AGG#DIM#profiles#\(Self.month)/3-5"))
    }

    @Test("An install that changed nothing this month is still censused for its version")
    func versionCensusIsMonthly() {
        // The bug present in both Orthanc and odvpn: driving the version spread from
        // `firstThisVersion` alone means `AGG#VER#2026-08` holds only the installs that *changed*
        // version during August, and none of the ones that stayed put.
        let stayedPut = PingHandler.plan(
            for: Self.request(firstToday: true, firstThisMonth: true),
            at: Self.now,
            accepting: Self.telemetry)
        #expect(Self.keys(stayedPut).contains("AGG#VER#\(Self.month)/2.1.0"))
    }

    @Test("An upgrade mid-month writes the new version once")
    func upgradeMidMonth() {
        let writes = PingHandler.plan(
            for: Self.request(firstThisVersion: true, appVersion: "2.2.0"),
            at: Self.now,
            accepting: Self.telemetry)
        #expect(Self.keys(writes) == ["AGG#VER#\(Self.month)/2.2.0"])
    }

    @Test("Two rules naming the same counter write it once")
    func deduplicatesTheVersionCounter() {
        let writes = PingHandler.plan(
            for: Self.request(firstThisMonth: true, firstThisVersion: true),
            at: Self.now,
            accepting: Self.telemetry)
        // Both the monthly census and the upgrade rule name `AGG#VER#2026-08/2.1.0`. Counting it
        // twice would inflate the version spread past MAU on every new month.
        #expect(Self.keys(writes).filter { $0 == "AGG#VER#\(Self.month)/2.1.0" }.count == 1)
    }

    @Test("Dimensions follow the config's declaration order, not the request's")
    func dimensionOrderIsDeterministic() {
        let writes = PingHandler.plan(
            for: Self.request(
                firstThisMonth: true, dimensions: ["theme": "dark", "profiles": "6-10"]),
            at: Self.now,
            accepting: Self.telemetry)
        let dimensionKeys = Self.keys(writes).filter { $0.hasPrefix("AGG#DIM#") }
        // A `[String: String]` iterates differently between runs; walking `telemetry.dimensions`
        // is what makes this assertion meaningful rather than flaky.
        #expect(
            dimensionKeys == [
                "AGG#DIM#profiles#\(Self.month)/6-10",
                "AGG#DIM#theme#\(Self.month)/dark",
            ])
    }

    @Test("A dimension the config does not declare is not written")
    func unknownDimensionIsDropped() {
        let writes = PingHandler.plan(
            for: Self.request(firstThisMonth: true, dimensions: ["unknown": "x"]),
            at: Self.now,
            accepting: Self.telemetry)
        #expect(!Self.keys(writes).contains { $0.hasPrefix("AGG#DIM#") })
    }

    @Test("A bucket outside the allowlist is not written")
    func unknownBucketIsDropped() {
        let writes = PingHandler.plan(
            for: Self.request(firstThisMonth: true, dimensions: ["profiles": "42"]),
            at: Self.now,
            accepting: Self.telemetry)
        // Unchecked, one client sending a raw number per request mints a sort key per value —
        // which is also the privacy leak the buckets exist to prevent.
        #expect(!Self.keys(writes).contains { $0.hasPrefix("AGG#DIM#") })
    }

    @Test("A config declaring no dimensions accepts none")
    func noDeclaredDimensions() {
        let writes = PingHandler.plan(
            for: Self.request(firstThisMonth: true, dimensions: ["profiles": "3-5"]),
            at: Self.now,
            accepting: .default)
        #expect(!Self.keys(writes).contains { $0.hasPrefix("AGG#DIM#") })
    }

    @Test("An empty bucket list accepts nothing rather than everything")
    func emptyBucketListIsNotAWildcard() {
        let writes = PingHandler.plan(
            for: Self.request(firstThisMonth: true, dimensions: ["open": "anything"]),
            at: Self.now,
            accepting: TelemetrySettings(dimensions: [DimensionConfig(name: "open", buckets: [])]))
        // A dimension that accepts any string is the unbounded-partition problem the allowlist
        // exists to prevent, so there is deliberately no way to spell it.
        #expect(!Self.keys(writes).contains { $0.hasPrefix("AGG#DIM#") })
    }

    @Test("Every boolean off plans nothing")
    func noOpPlansNothing() {
        #expect(
            PingHandler.plan(for: Self.request(), at: Self.now, accepting: Self.telemetry).isEmpty)
    }

    @Test("The plan never exceeds nine writes plus one per accepted dimension")
    func planIsBounded() {
        let writes = PingHandler.plan(
            for: Self.request(
                firstPingEver: true, firstToday: true, firstThisMonth: true,
                firstThisVersion: true, firstPaidLaunch: true,
                dimensions: ["profiles": "3-5", "theme": "dark"]),
            at: Self.now,
            accepting: Self.telemetry)
        // Nine distinct counters is the maximum a single request can move, and it is bounded by
        // construction: `AGG#VER` is named twice and counted once. §11's cost model depends on it.
        #expect(writes.count == 9 + 2)
        #expect(Set(writes).count == writes.count)
    }

    // MARK: - Validation

    @Test("A well-formed request validates")
    func validatesGoodRequest() throws {
        try PingHandler.validate(Self.request(dimensions: ["profiles": "3-5"]))
    }

    @Test(
        "An over-long or malformed key component is a 400, never truncated",
        arguments: [
            ("", "must not be empty"),
            (String(repeating: "9", count: 21), "at most 20 bytes"),
            ("2.1.0 beta", "printable ASCII"),
            ("2.1.0\t", "printable ASCII"),
            ("2.1.0\u{0}", "printable ASCII"),
            // 19 ASCII digits plus a two-byte `é` is 21 bytes and only 20 characters, which is the
            // whole reason the limit counts bytes: the sort key carries the bytes.
            (String(repeating: "9", count: 19) + "é", "at most 20 bytes"),
        ])
    func rejectsBadAppVersion(value: String, reason: String) {
        // Truncating instead would merge `2.1.0` with `2.1.0-verylongsuffix` on the same counter,
        // which nobody would ever notice was wrong.
        let error = #expect(throws: KeelError.self) {
            try PingHandler.validate(Self.request(appVersion: value))
        }
        #expect(error?.statusCode == 400)
        #expect(error?.message.contains("appVersion") == true)
        #expect(error?.message.contains(reason) == true)
    }

    @Test("The value that failed validation is never echoed back")
    func doesNotEchoTheValue() {
        let error = #expect(throws: KeelError.self) {
            try PingHandler.validate(Self.request(osVersion: "26.1 secret-build-name"))
        }
        // It came from a request body, and `docs/PRIVACY.md` promises those are not echoed.
        #expect(error?.message.contains("secret") == false)
        #expect(error?.message.contains("osVersion") == true)
    }

    @Test("Too many dimensions is a 400 rather than a silent subset")
    func rejectsTooManyDimensions() {
        var dimensions: [String: String] = [:]
        for index in 0...PingRequest.Limits.dimensionCount {
            dimensions["d\(index)"] = "v"
        }
        // "Keep 8 of 20" is nondeterministic — `[String: String]` iteration order decides which —
        // so a chart built from it would be quietly wrong in a different way each deploy.
        let error = #expect(throws: KeelError.self) {
            try PingHandler.validate(Self.request(dimensions: dimensions))
        }
        #expect(error?.statusCode == 400)
    }

    @Test("A dimension name or bucket over its limit is a 400")
    func rejectsOversizeDimensionStrings() {
        let long = String(repeating: "n", count: 33)
        #expect(throws: KeelError.self) {
            try PingHandler.validate(Self.request(dimensions: [long: "1-2"]))
        }
        #expect(throws: KeelError.self) {
            try PingHandler.validate(Self.request(dimensions: ["profiles": long]))
        }
    }

    // MARK: - Effects

    @Test("A first-ever launch lands every counter in the table")
    func performsThePlan() async throws {
        let store = InMemoryCounterStore()
        let handler = Self.handler(store: store)

        let ack = try await handler.handle(
            Self.request(
                firstPingEver: true, firstToday: true, firstThisMonth: true,
                firstThisVersion: true, dimensions: ["profiles": "3-5"]))

        #expect(ack == PingAck())
        #expect(store.count(partitionKey: "AGG#INSTALLS", sortKey: "TOTAL") == 1)
        #expect(store.count(partitionKey: "AGG#DAU", sortKey: Self.day) == 1)
        #expect(store.count(partitionKey: "AGG#DAU#free", sortKey: Self.day) == 1)
        #expect(store.count(partitionKey: "AGG#MAU", sortKey: Self.month) == 1)
        #expect(store.count(partitionKey: "AGG#VER#\(Self.month)", sortKey: "2.1.0") == 1)
        #expect(store.count(partitionKey: "AGG#OS#\(Self.month)", sortKey: "26.1") == 1)
        #expect(store.count(partitionKey: "AGG#PLAT#\(Self.month)", sortKey: "ios") == 1)
        #expect(store.count(partitionKey: "AGG#DIM#profiles#\(Self.month)", sortKey: "3-5") == 1)
    }

    @Test("Increments accumulate")
    func incrementsAccumulate() async throws {
        let store = InMemoryCounterStore()
        let handler = Self.handler(store: store)
        for _ in 0..<3 {
            _ = try await handler.handle(Self.request(firstToday: true))
        }
        #expect(store.count(partitionKey: "AGG#DAU", sortKey: Self.day) == 3)
    }

    @Test("The server-side kill switch writes nothing and still answers 200")
    func killSwitch() async throws {
        let store = InMemoryCounterStore()
        let logHandler = InMemoryLogHandler()
        let handler = Self.handler(
            store: store,
            config: RemoteConfig(telemetry: .disabled),
            handler: logHandler)

        let ack = try await handler.handle(
            Self.request(firstPingEver: true, firstToday: true, firstThisMonth: true))

        // Not an error: an error would make clients retry, and the point of the switch is to stop
        // counting, not to generate traffic.
        #expect(ack == PingAck())
        #expect(store.writes.isEmpty)
        #expect(store.partitionKeys.isEmpty)
        #expect(logHandler.hasEntry(atLeast: .debug, containing: "disabled"))
    }

    @Test("The kill switch is read from the live config, so it takes effect within the TTL")
    func killSwitchTakesEffect() async throws {
        let store = InMemoryCounterStore()
        let configStore = InMemoryConfigStore(RemoteConfig(telemetry: .default))
        let clock = TestClock()
        let handler = PingHandler(
            store: store,
            cache: ConfigCache(store: configStore, ttl: 60, clock: clock.callable),
            clock: clock.callable)

        _ = try await handler.handle(Self.request(firstToday: true))
        #expect(store.writes.count == 2)

        configStore.set(RemoteConfig(telemetry: .disabled))
        clock.advance(by: 60)
        _ = try await handler.handle(Self.request(firstToday: true))

        // `keel config set telemetry.enabled false` lands one TTL later, with no deploy.
        #expect(store.writes.count == 2)
    }

    @Test("A no-op ping costs nothing")
    func noOpWritesNothing() async throws {
        let store = InMemoryCounterStore()
        let ack = try await Self.handler(store: store).handle(Self.request())
        #expect(ack == PingAck())
        #expect(store.writes.isEmpty)
    }

    @Test("A malformed request is rejected before the config is even read")
    func validationPrecedesEverything() async {
        let store = InMemoryCounterStore()
        await #expect(throws: KeelError.self) {
            try await Self.handler(store: store).handle(
                Self.request(firstToday: true, appVersion: ""))
        }
        #expect(store.writes.isEmpty)
    }

    @Test("One failing counter does not lose the others")
    func partialFailureIsBestEffort() async throws {
        let store = InMemoryCounterStore()
        store.failWrites(to: "AGG#DAU")
        let logHandler = InMemoryLogHandler()
        let handler = Self.handler(store: store, handler: logHandler)

        // A throttled counter loses one increment, which tomorrow's dedup boolean re-offers. A
        // failed request loses the whole ping and teaches the client to retry a non-idempotent
        // write.
        let ack = try await handler.handle(Self.request(firstToday: true))
        #expect(ack == PingAck())
        #expect(store.count(partitionKey: "AGG#DAU", sortKey: Self.day) == 0)
        #expect(store.count(partitionKey: "AGG#DAU#free", sortKey: Self.day) == 1)
        #expect(logHandler.hasEntry(atLeast: .warning, containing: "Dropped one counter"))
    }

    @Test("Every counter failing is still a 200")
    func totalFailureIsStillAnAck() async throws {
        let store = InMemoryCounterStore()
        store.failAllWrites()
        let ack = try await Self.handler(store: store).handle(
            Self.request(firstPingEver: true, firstToday: true))
        #expect(ack == PingAck())
        #expect(store.writes.count == 3)
        #expect(store.partitionKeys.isEmpty)
    }

    @Test("An unreadable config table does not stop the counting")
    func unreadableConfigStillCounts() async throws {
        let store = InMemoryCounterStore()
        let configStore = InMemoryConfigStore(nil)
        configStore.failLoads()
        let handler = PingHandler(
            store: store,
            cache: ConfigCache(store: configStore, ttl: 60, clock: { Self.now }),
            clock: { Self.now })

        // Fails open, via `ConfigCache`'s fallback: an outage must not silently stop collection,
        // because "no data" and "no users" are indistinguishable afterwards.
        _ = try await handler.handle(Self.request(firstToday: true))
        #expect(store.count(partitionKey: "AGG#DAU", sortKey: Self.day) == 1)
    }

    @Test("A rejected dimension is logged by name and never by value")
    func logsRejectedDimensionNamesOnly() async throws {
        let store = InMemoryCounterStore()
        let logHandler = InMemoryLogHandler()
        let handler = Self.handler(store: store, handler: logHandler)

        _ = try await handler.handle(
            Self.request(
                firstThisMonth: true,
                dimensions: ["profiles": "4000", "unlisted": "sensitive-bucket"]))

        let warnings = logHandler.entries.filter { $0.level == .warning }
        #expect(warnings.count == 1)
        let rendered = warnings.map { "\($0.message) \($0.metadata)" }.joined()
        #expect(rendered.contains("profiles"))
        #expect(rendered.contains("unlisted"))
        // A dimension name comes from the app's own schema; a bucket label is derived from
        // something about the user, and `docs/PRIVACY.md` says neither the body nor anything
        // derived from it is logged.
        #expect(!rendered.contains("sensitive-bucket"))
        #expect(!rendered.contains("4000"))
    }

    @Test("An accepted ping logs no warning")
    func quietOnSuccess() async throws {
        let store = InMemoryCounterStore()
        let logHandler = InMemoryLogHandler()
        _ = try await Self.handler(store: store, handler: logHandler).handle(
            Self.request(firstThisMonth: true, dimensions: ["profiles": "3-5"]))
        #expect(!logHandler.entries.contains { $0.level >= .warning })
    }

    @Test("Which dimensions the config rejects is reported in sorted order")
    func rejectedDimensionsAreSorted() {
        let rejected = PingHandler.rejectedDimensions(
            in: Self.request(dimensions: ["zebra": "x", "profiles": "42", "alpha": "y"]),
            accepting: Self.telemetry)
        #expect(rejected == ["alpha", "profiles", "zebra"])
    }
}

public import Logging

#if canImport(FoundationEssentials)
public import FoundationEssentials
#else
public import Foundation
#endif

/// `POST /v1/ping` — turn five booleans into atomic counter increments.
///
/// Nothing here accepts, derives, logs or stores an identifier, and there is no request field that
/// could carry one (`docs/ARCHITECTURE.md` §9). Deduplication happened on the device; the handler
/// trusts the booleans, which is the accuracy trade-off recorded in
/// `docs/adr/0004-client-side-dedup-no-identifier.md`.
///
/// Three properties, in the order they matter:
///
/// 1. **The plan is pure.** `plan(for:at:accepting:)` maps a request to the exact set of writes,
///    with no store and no clock of its own, so the fan-out is asserted directly instead of
///    inferred from a fake's side effects.
/// 2. **The writes are best-effort.** They run concurrently and a failure is logged, not
///    propagated. A throttled counter loses one increment, which tomorrow's dedup boolean
///    re-offers; a failed request loses the whole ping and teaches the client to retry a write
///    that is not idempotent.
/// 3. **The kill switch is honoured here too.** `telemetry.enabled == false` returns `{"ok": true}`
///    having written nothing. Not an error: an error would make clients retry, and the point of
///    the switch is to stop counting, not to generate traffic.
public struct PingHandler: Sendable {
    let store: any CounterStore
    let cache: ConfigCache
    let clock: @Sendable () -> Date
    let logger: Logger

    public init(
        store: any CounterStore,
        cache: ConfigCache,
        clock: @escaping @Sendable () -> Date = { Date() },
        logger: Logger = Logger(label: "keel.ping")
    ) {
        self.store = store
        self.cache = cache
        self.clock = clock
        self.logger = logger
    }

    /// Validates, plans, and performs. Throws only on a malformed request.
    public func handle(_ request: PingRequest) async throws(KeelError) -> PingAck {
        try Self.validate(request)

        let config = await cache.current()
        guard config.telemetry.isEnabled else {
            logger.debug("Telemetry is disabled server-side; wrote nothing")
            return PingAck()
        }

        // A client should not have sent this, but a client that does costs nothing rather than a
        // wasted `GetItem`-and-nothing round trip being mistaken for a working ping.
        guard !request.isNoOp else {
            logger.debug("Ping with no flag set; wrote nothing")
            return PingAck()
        }

        let rejected = Self.rejectedDimensions(in: request, accepting: config.telemetry)
        if !rejected.isEmpty {
            // Names only, never buckets. A dimension name comes from the app's own schema; a
            // bucket label is derived from something about the user, and `docs/PRIVACY.md` says
            // nothing derived from a request body is logged. The name is what an operator needs
            // to run `keel config set` and the bucket adds nothing to that.
            logger.warning(
                "Dropped dimensions the config does not accept",
                metadata: ["names": .string(rejected.joined(separator: ", "))])
        }

        let writes = Self.plan(for: request, at: clock(), accepting: config.telemetry)
        await perform(writes)
        return PingAck()
    }

    // MARK: - Validation

    /// Rejects, never truncates.
    ///
    /// Every string validated here becomes a DynamoDB key, so the limits are not cosmetic: an
    /// unbounded version string means an unbounded number of sort keys, and an unbounded dimension
    /// name means a partition per typo that nothing reads and nothing cleans up.
    ///
    /// Truncating instead would be worse than rejecting in a way that is hard to see later: `2.1.0`
    /// and `2.1.0-verylongsuffix` would land on the same counter, and a distribution with eight
    /// arbitrary dimensions kept out of twenty is a chart nobody can tell is wrong. A 400 is
    /// noticed during development, which is where a client bug should be caught.
    static func validate(_ request: PingRequest) throws(KeelError) {
        try validateKeyComponent(
            request.appVersion, field: "appVersion", limit: PingRequest.Limits.versionLength)
        try validateKeyComponent(
            request.osVersion, field: "osVersion", limit: PingRequest.Limits.versionLength)

        guard request.dimensions.count <= PingRequest.Limits.dimensionCount else {
            throw .badRequest(
                field: "dimensions",
                reason: "at most \(PingRequest.Limits.dimensionCount) are accepted")
        }
        for (name, bucket) in request.dimensions {
            try validateKeyComponent(
                name, field: "dimensions.name", limit: PingRequest.Limits.dimensionNameLength)
            try validateKeyComponent(
                bucket, field: "dimensions.value", limit: PingRequest.Limits.dimensionValueLength)
        }
    }

    /// Non-empty, within `limit` UTF-8 bytes, and printable ASCII with no spaces.
    ///
    /// Bytes rather than characters because the limit is about key size. Printable-and-spaceless
    /// because these are keys an operator reads in the console and a dashboard renders as a chart
    /// label; a tab or a control byte in a sort key is never a value anybody meant to send.
    ///
    /// The reason is returned to the caller but the *value* never is — it came from a request body,
    /// and `docs/PRIVACY.md` promises those are not echoed or logged.
    private static func validateKeyComponent(
        _ value: String, field: String, limit: Int
    ) throws(KeelError) {
        guard !value.isEmpty else {
            throw .badRequest(field: field, reason: "must not be empty")
        }
        guard value.utf8.count <= limit else {
            throw .badRequest(field: field, reason: "must be at most \(limit) bytes")
        }
        guard value.utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7F }) else {
            throw .badRequest(field: field, reason: "must be printable ASCII without spaces")
        }
    }

    // MARK: - The plan

    /// Every counter this request moves, de-duplicated, in a stable order.
    ///
    /// Which boolean drives which counter is the design decision in this file, and the two
    /// existing implementations disagreed:
    ///
    /// | Boolean | Writes |
    /// |---|---|
    /// | `firstPingEver` | `AGG#INSTALLS` |
    /// | `firstPaidLaunch` | `AGG#CONVERSIONS` |
    /// | `firstToday` | `AGG#DAU`, `AGG#DAU#<state>` |
    /// | `firstThisMonth` | `AGG#MAU`, `AGG#MAU#<state>`, `AGG#OS#<month>`, `AGG#PLAT#<month>`, `AGG#VER#<month>`, one `AGG#DIM#<name>#<month>` per accepted dimension |
    /// | `firstThisVersion` | `AGG#VER#<month>` |
    ///
    /// **OS, platform and dimensions are monthly, not daily.** Incrementing the OS spread on
    /// `firstToday` would make its total a sum of daily actives — comparable to nothing else
    /// published. Deduping them monthly makes `sum(osVersions) ≈ mau`: one observation per install
    /// per month, the same census the MAU counter takes.
    ///
    /// **The version spread is both monthly and on upgrade.** Driving it from `firstThisVersion`
    /// alone is subtly broken: that boolean fires once per install per *version
    /// ever*, so `AGG#VER#2026-09` would contain only the installs that changed version during
    /// September and none of the ones that stayed put. Adding the monthly census fixes it. An
    /// install that upgrades mid-month is then counted under both versions for that month, so
    /// `sum(versions)` can exceed `mau` — which is the honest reading of "was seen on this
    /// version this month", and better than a distribution that omits everyone who did not move.
    ///
    /// De-duplication is what makes those two rules compose: a first launch that is also a new
    /// month writes `AGG#VER#<month>/<version>` once, not twice.
    ///
    /// The result is 1–9 writes plus one per accepted dimension. A returning install on its second
    /// launch of the day sends nothing at all (`PingRequest.isNoOp`), which is what keeps the cost
    /// model in §11 flat.
    static func plan(
        for request: PingRequest, at now: Date, accepting telemetry: TelemetrySettings
    ) -> [CounterWrite] {
        let ttl = CounterSchema.expiry(from: now)
        let day = CounterSchema.daySortKey(now)
        let month = CounterSchema.monthSortKey(now)

        var writes: [CounterWrite] = []
        var seen: Set<CounterWrite> = []
        // Order is preserved for readability in tests and logs; the set is what enforces the
        // "count it once" rule when two rules name the same item.
        func add(_ partitionKey: String, _ sortKey: String, ttl: Int?) {
            let write = CounterWrite(partitionKey: partitionKey, sortKey: sortKey, ttl: ttl)
            guard seen.insert(write).inserted else { return }
            writes.append(write)
        }

        // Lifetime totals get no TTL at all — see `CounterSchema.expiry`.
        if request.firstPingEver {
            add(CounterSchema.installsPartitionKey, CounterSchema.totalSortKey, ttl: nil)
        }
        if request.firstPaidLaunch {
            add(CounterSchema.conversionsPartitionKey, CounterSchema.totalSortKey, ttl: nil)
        }
        if request.firstToday {
            add(CounterSchema.dauPartitionKey, day, ttl: ttl)
            add(CounterSchema.dau(state: request.licenseState), day, ttl: ttl)
        }
        if request.firstThisMonth {
            add(CounterSchema.mauPartitionKey, month, ttl: ttl)
            add(CounterSchema.mau(state: request.licenseState), month, ttl: ttl)
            add(CounterSchema.osVersions(month: now), request.osVersion, ttl: ttl)
            add(CounterSchema.platforms(month: now), request.platform.rawValue, ttl: ttl)
            add(CounterSchema.versions(month: now), request.appVersion, ttl: ttl)

            // Declaration order, not the request's dictionary order, so the plan is deterministic:
            // a `[String: String]` iterates differently between runs and the assertions in
            // `PingHandlerTests` would be flaky for no reason.
            for dimension in telemetry.dimensions {
                guard let bucket = request.dimensions[dimension.name] else { continue }
                guard dimension.buckets.contains(bucket) else { continue }
                add(CounterSchema.dimension(name: dimension.name, month: now), bucket, ttl: ttl)
            }
        }
        if request.firstThisVersion {
            add(CounterSchema.versions(month: now), request.appVersion, ttl: ttl)
        }
        return writes
    }

    /// The dimensions in this request the config does not accept, for the log.
    ///
    /// Unknown names and unknown buckets are **dropped, not rejected** — the opposite of a limit
    /// violation. The allowlist legitimately lags a client rollout: a new dimension ships in an
    /// app-store build before somebody runs `keel config set`, and failing the whole ping over it
    /// would throw away that install's DAU count to protect a chart nobody is looking at yet.
    /// Logging is what keeps "lagging" from becoming "forgotten".
    static func rejectedDimensions(
        in request: PingRequest, accepting telemetry: TelemetrySettings
    ) -> [String] {
        request.dimensions.keys
            .filter { name in
                guard let bucket = request.dimensions[name] else { return false }
                return !telemetry.accepts(dimension: name, bucket: bucket)
            }
            .sorted()
    }

    // MARK: - Effects

    /// Perform the plan concurrently, logging failures instead of raising them.
    ///
    /// `withDiscardingTaskGroup` rather than `async let`: the count is data-dependent, and there
    /// is nothing to collect. Nine independent single-item `UpdateItem` calls issued serially
    /// would spend nine round trips on a request whose entire job is those nine writes.
    private func perform(_ writes: [CounterWrite]) async {
        await withDiscardingTaskGroup { group in
            for write in writes {
                group.addTask {
                    do {
                        try await store.increment(write)
                    } catch {
                        // The key is safe to log — it is built by `CounterSchema` out of a clock
                        // and a validated enum, never out of free text from the body.
                        logger.warning(
                            "Dropped one counter increment",
                            metadata: [
                                "pk": .string(write.partitionKey),
                                "sk": .string(write.sortKey),
                                "error": "\(error)",
                            ])
                    }
                }
            }
        }
    }
}

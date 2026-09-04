/// One row of an `AGG#` partition: a sort key and its atomic count.
///
/// `2026-08-24 / 611` out of `AGG#DAU`, or `2.1.0 / 2980` out of `AGG#VER#2026-08`. The
/// partition it came from is the caller's context, so it is not repeated here.
public struct CounterRow: Sendable, Equatable {
    public var sortKey: String
    public var count: Int

    public init(sortKey: String, count: Int) {
        self.sortKey = sortKey
        self.count = count
    }
}

/// A single counter increment, fully described: the item to touch and whether it expires.
///
/// `PingHandler` builds an array of these *before* it performs any of them, which is what makes
/// the fan-out testable without a store and without a clock — see `PingHandler.plan(for:now:)`.
/// `Hashable` because the plan is de-duplicated: two rules can legitimately target the same item
/// on the same request, and the second must not double-count it.
public struct CounterWrite: Sendable, Equatable, Hashable {
    public var partitionKey: String
    public var sortKey: String

    /// Epoch **seconds**, or nil for the lifetime totals. Nil rather than a far-future value:
    /// an absent attribute is unambiguous, and any date picked today as "far enough" arrives.
    public var ttl: Int?

    public init(partitionKey: String, sortKey: String, ttl: Int?) {
        self.partitionKey = partitionKey
        self.sortKey = sortKey
        self.ttl = ttl
    }
}

/// The counter table, as the handlers see it.
///
/// Named `CounterStore` rather than `DeviceStore` or `UsageStore` on purpose: aggregate counters
/// are the *only* thing this table holds, and a name implying per-device rows would keep the
/// reader looking for them (`docs/ARCHITECTURE.md` §9).
///
/// Two operations, both of which map to exactly one DynamoDB call. There is no `get`, no `put`,
/// and no `delete`, because the counters are write-only-by-increment and read-only-by-window —
/// anything else would be a shape the schema does not support.
public protocol CounterStore: Sendable {
    /// `UpdateItem` with `ADD #count :one`. An upsert, atomic across any number of concurrent
    /// devices — no read-modify-write, no condition expression, no contention.
    ///
    /// Idempotent it is **not**: calling it twice counts twice. Retries are therefore the
    /// caller's decision, and `PingHandler` deliberately does not retry.
    func increment(_ write: CounterWrite) async throws

    /// Every row of one partition in ascending sort-key order — a `Query`, never a `Scan`.
    ///
    /// `sortKeyFrom` is an inclusive lower bound, which is how a 30-day window costs one request
    /// against a partition holding 400 days. Nil reads the whole partition, which is only ever
    /// used where the partition is bounded by construction (a month of versions, or the single
    /// `TOTAL` row).
    func query(partitionKey: String, sortKeyFrom: String?) async throws -> [CounterRow]
}

extension CounterStore {
    /// Read a single counter: the one row a lifetime-total partition holds.
    ///
    /// Zero for an absent item rather than nil. "Nobody has installed it yet" and "the counter
    /// does not exist yet" are the same fact here, and forcing every caller to unwrap the
    /// distinction would only invite `?? 0` at each site.
    public func total(partitionKey: String, sortKey: String) async throws -> Int {
        try await query(partitionKey: partitionKey, sortKeyFrom: sortKey)
            .first { $0.sortKey == sortKey }?.count ?? 0
    }
}

/// The remote configuration item, `CONFIG#current` / `v1`.
///
/// Separate from `CounterStore` because it is a different access pattern on the same table —
/// a keyed read of one item, and a write that replaces it wholesale — and because a handler that
/// only needs config should not be handed the ability to increment counters.
public protocol ConfigStore: Sendable {
    /// The stored config, or nil when the item does not exist.
    ///
    /// Nil is a real and expected answer: a freshly deployed stack has an empty table, and the
    /// framework's response to that is to serve compiled-in defaults rather than to fail. It is
    /// distinct from a thrown error, which means "the table could not be read" — the first is
    /// answered with defaults, the second with the last known good value.
    func load() async throws -> RemoteConfig?

    /// Replace the item. Used by `keel config set`; no handler writes config.
    func save(_ config: RemoteConfig) async throws
}

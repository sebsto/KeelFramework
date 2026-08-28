public import KeelServer
import Synchronization

/// A `CounterStore` in a dictionary, with failures you can ask for.
///
/// A `final class` rather than an `actor` so a test can read `store.writes` without an `await`.
/// Nothing here suspends, so there is no concurrency for an actor to protect that a `Mutex` does
/// not — and `#expect(store.writes == [...])` reads better than `await store.writes()`.
///
/// It models the two DynamoDB operations and nothing else, which is the point: there is no `get`,
/// no `put`, and no way to set a count to an arbitrary value except by seeding it, so a test
/// cannot accidentally assert behaviour the real store could not produce.
public final class InMemoryCounterStore: CounterStore {
    /// A read, recorded. Tests assert the *number* of these as much as their content: the stats
    /// endpoint's cost is its query count, and a regression that turns one windowed Query into
    /// thirty per-day reads is invisible in the response body.
    public struct Query: Sendable, Equatable {
        public var partitionKey: String
        public var sortKeyFrom: String?

        public init(partitionKey: String, sortKeyFrom: String? = nil) {
            self.partitionKey = partitionKey
            self.sortKeyFrom = sortKeyFrom
        }
    }

    /// Thrown by `increment` when the write was set to fail. Carries the key so a test can assert
    /// *which* write failed rather than that something did.
    public struct WriteFailure: Error, Equatable, Sendable {
        public var partitionKey: String
        public var sortKey: String
    }

    /// Thrown by `query` when the read was set to fail.
    public struct ReadFailure: Error, Equatable, Sendable {
        public var partitionKey: String
    }

    private struct State {
        var counts: [String: [String: Int]] = [:]
        var attempts: [CounterWrite] = []
        var queries: [Query] = []
        var failingWrites: Set<String> = []
        var failingReads: Set<String> = []
        var allWritesFail = false
        var allReadsFail = false
    }

    private let state = Mutex(State())

    public init() {}

    // MARK: - Inspection

    /// Every increment the store was *asked* to perform, in order, including the ones set to fail.
    ///
    /// Attempts rather than successes, deliberately: `PingHandler` swallows write failures, so the
    /// only way to assert it still tried is to record the attempt. What landed is `count(_:_:)`.
    public var writes: [CounterWrite] { state.withLock { $0.attempts } }

    public var queries: [Query] { state.withLock { $0.queries } }

    /// The current value of one counter. Zero when it was never written, matching
    /// `CounterStore.total`.
    public func count(partitionKey: String, sortKey: String) -> Int {
        state.withLock { $0.counts[partitionKey]?[sortKey] ?? 0 }
    }

    /// Every partition that holds at least one row, sorted. Used to assert a handler wrote nothing
    /// at all — `#expect(store.partitionKeys.isEmpty)` says it better than counting writes.
    public var partitionKeys: [String] {
        state.withLock { $0.counts.filter { !$0.value.isEmpty }.keys.sorted() }
    }

    // MARK: - Setup

    /// Pre-load a counter, as if devices had already pinged it.
    public func seed(partitionKey: String, sortKey: String, count: Int) {
        state.withLock { $0.counts[partitionKey, default: [:]][sortKey] = count }
    }

    /// Pre-load a whole partition: `seed("AGG#DAU", ["2026-08-24": 611, "2026-08-23": 588])`.
    public func seed(_ partitionKey: String, _ rows: [String: Int]) {
        state.withLock { $0.counts[partitionKey, default: [:]].merge(rows) { _, new in new } }
    }

    /// Make increments to one partition throw. Other partitions keep working, which is the case
    /// that matters: a partially-failed ping must still count what it can.
    public func failWrites(to partitionKey: String) {
        state.withLock { _ = $0.failingWrites.insert(partitionKey) }
    }

    public func failAllWrites() {
        state.withLock { $0.allWritesFail = true }
    }

    public func failReads(of partitionKey: String) {
        state.withLock { _ = $0.failingReads.insert(partitionKey) }
    }

    public func failAllReads() {
        state.withLock { $0.allReadsFail = true }
    }

    // MARK: - CounterStore

    public func increment(_ write: CounterWrite) async throws {
        try state.withLock { state in
            state.attempts.append(write)
            guard !state.allWritesFail, !state.failingWrites.contains(write.partitionKey) else {
                throw WriteFailure(partitionKey: write.partitionKey, sortKey: write.sortKey)
            }
            state.counts[write.partitionKey, default: [:]][write.sortKey, default: 0] += 1
        }
    }

    public func query(partitionKey: String, sortKeyFrom: String?) async throws -> [CounterRow] {
        try state.withLock { state in
            state.queries.append(Query(partitionKey: partitionKey, sortKeyFrom: sortKeyFrom))
            guard !state.allReadsFail, !state.failingReads.contains(partitionKey) else {
                throw ReadFailure(partitionKey: partitionKey)
            }
            // Ascending, and filtered by an inclusive lower bound — the two properties of a real
            // Query that a handler is entitled to rely on. Returning insertion order instead
            // would let a broken zero-fill pass here and scramble the chart in production.
            return (state.counts[partitionKey] ?? [:])
                .filter { row in
                    guard let from = sortKeyFrom else { return true }
                    return row.key >= from
                }
                .map { CounterRow(sortKey: $0.key, count: $0.value) }
                .sorted { $0.sortKey < $1.sortKey }
        }
    }
}

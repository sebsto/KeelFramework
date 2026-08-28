public import KeelServer
import Synchronization

/// A `ConfigStore` in a variable, with a read count, injectable failure, and a gate.
///
/// The read count is the interesting part. `ConfigCache`'s whole job is to not read the store, and
/// the only way to assert that is to count: a TTL that does not expire, an expiry that does, and a
/// cold start that issues one `GetItem` for five concurrent callers are all statements about
/// `loadCount` and nothing else.
public final class InMemoryConfigStore: ConfigStore {
    /// Thrown by `load` and `save` when the store was set to fail. Deliberately opaque — every
    /// caller in `KeelServer` treats a store error as "unreadable" and inspects nothing.
    public struct Failure: Error, Equatable, Sendable {
        public init() {}
    }

    private struct State {
        var config: RemoteConfig?
        var loadCount = 0
        var saveCount = 0
        var loadsFail = false
        var savesFail = false
        var isHeld = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    public init(_ config: RemoteConfig? = nil) {
        state.withLock { $0.config = config }
    }

    // MARK: - Inspection

    public var loadCount: Int { state.withLock { $0.loadCount } }

    public var saveCount: Int { state.withLock { $0.saveCount } }

    /// What `save` last stored, or the seeded value.
    public var stored: RemoteConfig? { state.withLock { $0.config } }

    /// How many `load` calls are currently parked in `hold()`. A single-flight test polls this to
    /// know the first load has arrived before it releases the gate.
    public var heldLoadCount: Int { state.withLock { $0.waiters.count } }

    // MARK: - Setup

    /// Replace the stored item without counting a save. Nil models an empty table.
    public func set(_ config: RemoteConfig?) {
        state.withLock { $0.config = config }
    }

    public func failLoads() {
        state.withLock { $0.loadsFail = true }
    }

    /// Stop failing, so a test can assert recovery — `ConfigCache` deliberately does not cache a
    /// read failure, and the assertion for that is a load that succeeds on the very next call.
    public func succeedLoads() {
        state.withLock { $0.loadsFail = false }
    }

    public func failSaves() {
        state.withLock { $0.savesFail = true }
    }

    /// Park every subsequent `load` until `release()`.
    ///
    /// This is what makes the single-flight test deterministic rather than a race the fake usually
    /// wins: without a gate, an in-memory load returns before the second caller reaches the actor,
    /// and the test passes for the wrong reason.
    public func hold() {
        state.withLock { $0.isHeld = true }
    }

    /// Let every parked load through, and stop parking new ones.
    public func release() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.isHeld = false
            let parked = state.waiters
            state.waiters = []
            return parked
        }
        // Resumed outside the lock: a continuation can run its awaiting task immediately, and that
        // task may call straight back into this store.
        for waiter in waiters { waiter.resume() }
    }

    // MARK: - ConfigStore

    public func load() async throws -> RemoteConfig? {
        await waitIfHeld()
        return try state.withLock { state in
            state.loadCount += 1
            guard !state.loadsFail else { throw Failure() }
            return state.config
        }
    }

    public func save(_ config: RemoteConfig) async throws {
        try state.withLock { state in
            state.saveCount += 1
            guard !state.savesFail else { throw Failure() }
            state.config = config
        }
    }

    private func waitIfHeld() async {
        await withCheckedContinuation { continuation in
            let isHeld = state.withLock { state -> Bool in
                guard state.isHeld else { return false }
                state.waiters.append(continuation)
                return true
            }
            if !isHeld { continuation.resume() }
        }
    }
}

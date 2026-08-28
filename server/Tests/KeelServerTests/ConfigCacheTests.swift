import Foundation
import InMemoryLogging
import KeelServerTesting
import Logging
import Testing

@testable import KeelServer

/// `ConfigCache` has one job it must never fail at and one it must not do too often: always return
/// a config, and rarely read the store. Both are counted here — the read count is the only
/// observable difference between a working cache and a passthrough.
@Suite("Config cache")
struct ConfigCacheTests {

    /// A config distinguishable from `.empty`, so a test can tell "served the stored value" from
    /// "served the fallback".
    static let stored = RemoteConfig(features: ["stored": true])
    static let fallback = RemoteConfig(features: ["fallback": true])

    @Test("The stored config is served and then reused for the whole TTL")
    func servesAndCaches() async {
        let store = InMemoryConfigStore(Self.stored)
        let clock = TestClock()
        let cache = ConfigCache(store: store, ttl: 60, clock: clock.callable)

        #expect(await cache.current() == Self.stored)
        clock.advance(by: 59)
        #expect(await cache.current() == Self.stored)
        #expect(store.loadCount == 1)
    }

    @Test("Once the TTL expires the store is read again")
    func refreshesAfterTTL() async {
        let store = InMemoryConfigStore(Self.stored)
        let clock = TestClock()
        let cache = ConfigCache(store: store, ttl: 60, clock: clock.callable)

        _ = await cache.current()
        clock.advance(by: 60)
        store.set(RemoteConfig(features: ["stored": false]))

        #expect(await cache.current().features == ["stored": false])
        #expect(store.loadCount == 2)
    }

    @Test("An empty table serves the fallback, and does not re-read it every invocation")
    func missingItemServesFallback() async {
        let store = InMemoryConfigStore(nil)
        let cache = ConfigCache(store: store, fallback: Self.fallback, ttl: 60, clock: { Date() })

        #expect(await cache.current() == Self.fallback)
        #expect(await cache.current() == Self.fallback)
        // A freshly deployed stack is the *normal* state for a while. Treating an absent item as
        // an error would put a GetItem on every single invocation until somebody ran `keel config`.
        #expect(store.loadCount == 1)
    }

    @Test("A read failure with nothing cached serves the fallback rather than throwing")
    func failureWithNothingCached() async {
        let store = InMemoryConfigStore(Self.stored)
        store.failLoads()
        let handler = InMemoryLogHandler()
        let cache = ConfigCache(
            store: store, fallback: Self.fallback, ttl: 60, clock: { Date() },
            logger: handler.logger)

        #expect(await cache.current() == Self.fallback)
        #expect(handler.hasEntry(atLeast: .error, containing: "nothing cached"))
    }

    @Test("A read failure after a good load serves the stale copy")
    func failureServesStale() async {
        let store = InMemoryConfigStore(Self.stored)
        let clock = TestClock()
        let handler = InMemoryLogHandler()
        let cache = ConfigCache(
            store: store, fallback: Self.fallback, ttl: 60, clock: clock.callable,
            logger: handler.logger)

        #expect(await cache.current() == Self.stored)
        store.failLoads()
        clock.advance(by: 3_600)

        // An hour stale beats the fallback: the fallback has no idea what the operator configured,
        // and this is where the telemetry kill switch and the version gate live.
        #expect(await cache.current() == Self.stored)
        #expect(handler.hasEntry(atLeast: .warning, containing: "stale"))
    }

    @Test("A read failure is not cached, so recovery is immediate")
    func failureIsNotCached() async {
        let store = InMemoryConfigStore(Self.stored)
        let clock = TestClock()
        let cache = ConfigCache(store: store, ttl: 60, clock: clock.callable)

        store.failLoads()
        _ = await cache.current()
        #expect(store.loadCount == 1)

        // No clock movement: the next request must retry rather than serve a cached failure for a
        // whole TTL. One GetItem per invocation is the uncached baseline, so the worst case of
        // getting this wrong in the other direction is a kill switch that stays stuck for a minute.
        store.succeedLoads()
        #expect(await cache.current() == Self.stored)
        #expect(store.loadCount == 2)
    }

    @Test("Concurrent callers on a cold start share one read")
    func singleFlight() async {
        let store = InMemoryConfigStore(Self.stored)
        let cache = ConfigCache(store: store, ttl: 60, clock: { Date() })
        store.hold()

        let results = await withTaskGroup(of: RemoteConfig.self) { group in
            for _ in 0..<8 {
                group.addTask { await cache.current() }
            }
            // The gate is what makes this deterministic. Without it the first load returns before
            // the second caller reaches the actor, and the test would pass without ever exercising
            // the single-flight path.
            while store.heldLoadCount == 0 {
                await Task.yield()
            }
            store.release()
            var configs: [RemoteConfig] = []
            for await config in group { configs.append(config) }
            return configs
        }

        #expect(results.count == 8)
        #expect(results.allSatisfy { $0 == Self.stored })
        #expect(store.loadCount == 1)
    }

    @Test("Invalidating forces the next read")
    func invalidate() async {
        let store = InMemoryConfigStore(Self.stored)
        let cache = ConfigCache(store: store, ttl: 3_600, clock: { Date() })

        _ = await cache.current()
        await cache.invalidate()
        store.set(Self.fallback)

        #expect(await cache.current() == Self.fallback)
        #expect(store.loadCount == 2)
    }

    @Test("Telemetry stays enabled when the store is unreadable and the fallback is empty")
    func failsOpenOnTelemetry() async {
        let store = InMemoryConfigStore(nil)
        store.failLoads()
        let cache = ConfigCache(store: store, ttl: 60, clock: { Date() })

        // The kill switch must never be flipped by an outage. "No data" and "no users" are
        // indistinguishable after the fact.
        #expect(await cache.current().telemetry.isEnabled)
    }
}

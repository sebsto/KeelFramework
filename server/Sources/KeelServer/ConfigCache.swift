public import Logging

#if canImport(FoundationEssentials)
public import FoundationEssentials
#else
public import Foundation
#endif

/// The config item, cached for the life of a warm Lambda and refreshed on a TTL.
///
/// Every invocation needs the config — bootstrap projects it, ping checks the kill switch — and
/// reading it from DynamoDB each time would put a `GetItem` on the critical path of a request
/// whose whole job is two atomic increments. The TTL is what makes `keel config set` land
/// "within a minute" rather than instantly, and 60 seconds is the number the bootstrap response's
/// own `max-age` is chosen to match (`docs/ARCHITECTURE.md` §3).
///
/// **It never fails.** `current()` cannot throw and does not return an optional. In order of
/// preference it serves: a fresh value, a freshly loaded one, the last known good value however
/// stale, or the compiled-in fallback. A backend whose table is unreachable keeps serving the
/// config it last saw, which is the difference between a degraded launch and a broken one.
public actor ConfigCache {
    private struct Entry {
        var config: RemoteConfig
        var loadedAt: Date
    }

    private let store: any ConfigStore
    private let fallback: RemoteConfig
    private let ttl: TimeInterval
    private let clock: @Sendable () -> Date
    private let logger: Logger

    private var entry: Entry?

    /// The load in progress, if any, so concurrent callers share one `GetItem` instead of each
    /// issuing their own. Matters on a cold start where the runtime hands over several requests
    /// before the first load returns.
    private var inFlight: Task<RemoteConfig, Never>?

    /// - Parameters:
    ///   - store: where the config lives.
    ///   - fallback: what to serve when the store has no item, or cannot be read and nothing has
    ///     been cached yet. `.empty` is the right answer for most apps; an app with meaningful
    ///     compiled-in defaults passes those instead, so a cold start against a broken table
    ///     still serves something coherent.
    ///   - ttl: how long a loaded value stays fresh. Seconds.
    ///   - clock: injected so the TTL is testable without sleeping.
    ///   - logger: where a stale or unreadable config is reported. The handlers share theirs, so
    ///     one request's config trouble is visible beside whatever it caused.
    public init(
        store: any ConfigStore,
        fallback: RemoteConfig = .empty,
        ttl: TimeInterval = 60,
        clock: @escaping @Sendable () -> Date = { Date() },
        logger: Logger = Logger(label: "keel.config")
    ) {
        self.store = store
        self.fallback = fallback
        self.ttl = ttl
        self.clock = clock
        self.logger = logger
    }

    /// The best config available right now.
    public func current() async -> RemoteConfig {
        if let entry, clock().timeIntervalSince(entry.loadedAt) < ttl {
            return entry.config
        }
        if let inFlight {
            return await inFlight.value
        }
        let task = Task { await self.load() }
        inFlight = task
        let config = await task.value
        inFlight = nil
        return config
    }

    /// Drop the cached value so the next `current()` reads the store.
    ///
    /// For tests, and for a process that has just written the config and wants to see its own
    /// write — `keel config set` is a different process, so it cannot use this and relies on the
    /// TTL like everyone else.
    public func invalidate() {
        entry = nil
    }

    private func load() async -> RemoteConfig {
        do {
            let loaded = try await store.load()
            if loaded == nil {
                // Not an error: a freshly deployed stack has an empty table. Cache the fallback
                // so an unconfigured backend does not re-read the missing item every invocation.
                logger.debug("No config item; serving the fallback for this TTL")
            }
            let config = loaded ?? fallback
            entry = Entry(config: config, loadedAt: clock())
            return config
        } catch {
            // Note what is *not* here: the failure is not cached. The next request retries, which
            // is deliberate — this is where the telemetry kill switch and the version gate live,
            // and it should come back the moment the table does. One `GetItem` per invocation is
            // the cost of having no cache at all, so the worst case is the uncached baseline.
            if let entry {
                logger.warning(
                    "Config read failed; serving a stale copy",
                    metadata: [
                        "error": "\(error)",
                        "ageSeconds": "\(Int(clock().timeIntervalSince(entry.loadedAt)))",
                    ])
                return entry.config
            }
            logger.error(
                "Config read failed with nothing cached; serving the fallback",
                metadata: ["error": "\(error)"])
            return fallback
        }
    }
}

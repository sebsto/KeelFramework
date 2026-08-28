#if DEBUG
import KeelServer

/// A throwaway in-process store for `KEEL_MEMORY_STORE=1` local runs. Debug builds only.
///
/// Not `KeelServerTesting`'s fakes, on purpose: importing that product here would compile the
/// test doubles into the deployable binary, and this needs a fraction of what they offer — no
/// failure injection, no recorded calls, just enough state that `curl` shows a ping landing in
/// the stats.
actor MemoryStore: CounterStore, ConfigStore {
    private var counts: [String: Int] = [:]
    private var config: RemoteConfig?

    func increment(_ write: CounterWrite) async throws {
        counts["\(write.partitionKey)\u{1F}\(write.sortKey)", default: 0] += 1
    }

    func query(partitionKey: String, sortKeyFrom: String?) async throws -> [CounterRow] {
        counts.compactMap { key, count -> CounterRow? in
            let parts = key.split(separator: "\u{1F}", maxSplits: 1)
            guard parts.count == 2, parts[0] == partitionKey else { return nil }
            let sortKey = String(parts[1])
            if let sortKeyFrom, sortKey < sortKeyFrom { return nil }
            return CounterRow(sortKey: sortKey, count: count)
        }
        .sorted { $0.sortKey < $1.sortKey }
    }

    func load() async throws -> RemoteConfig? {
        config
    }

    func save(_ config: RemoteConfig) async throws {
        self.config = config
    }
}
#endif

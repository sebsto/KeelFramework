public import Foundation
public import KeelClient
import os

/// A `KeyValueStore` over a dictionary — `UserDefaults` for tests, without the shared
/// global state that makes test order matter.
///
/// A lock rather than an actor so assertions read synchronously:
/// `#expect(store.date(forKey: …) == nil)` with no `await`. `OSAllocatedUnfairLock`
/// rather than `Synchronization.Mutex` only because this package deploys to macOS 14,
/// a year short of the stdlib type.
public final class InMemoryKeyValueStore: KeyValueStore, Sendable {
    private let values = OSAllocatedUnfairLock<[String: any Sendable]>(initialState: [:])

    public init() {}

    public func bool(forKey key: String) -> Bool? {
        values.withLock { $0[key] as? Bool }
    }

    public func string(forKey key: String) -> String? {
        values.withLock { $0[key] as? String }
    }

    public func date(forKey key: String) -> Date? {
        values.withLock { $0[key] as? Date }
    }

    public func set(_ value: Bool, forKey key: String) {
        values.withLock { $0[key] = value }
    }

    public func set(_ value: String, forKey key: String) {
        values.withLock { $0[key] = value }
    }

    public func set(_ value: Date, forKey key: String) {
        values.withLock { $0[key] = value }
    }

    public func removeValue(forKey key: String) {
        values.withLock { $0[key] = nil }
    }

    /// Every stored key, for asserting that nothing unexpected was written.
    public var keys: Set<String> {
        values.withLock { Set($0.keys) }
    }
}

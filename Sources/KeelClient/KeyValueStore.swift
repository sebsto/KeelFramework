public import Foundation

/// The little slice of `UserDefaults` Keel needs, as a protocol so tests inject a
/// dictionary.
///
/// The accessors return optionals on purpose: `UserDefaults.bool(forKey:)` answers `false`
/// for an absent key, and "never touched the setting" versus "turned it off" is exactly the
/// distinction the telemetry opt-out depends on — absent means enabled
/// (`docs/PRIVACY.md`), and collapsing the two would disable telemetry for everyone who
/// never opened Settings.
public protocol KeyValueStore: Sendable {
    func bool(forKey key: String) -> Bool?
    func string(forKey key: String) -> String?
    func date(forKey key: String) -> Date?
    func set(_ value: Bool, forKey key: String)
    func set(_ value: String, forKey key: String)
    func set(_ value: Date, forKey key: String)
    func removeValue(forKey key: String)
}

extension UserDefaults: KeyValueStore {
    public func bool(forKey key: String) -> Bool? {
        object(forKey: key) as? Bool
    }

    public func date(forKey key: String) -> Date? {
        object(forKey: key) as? Date
    }

    public func set(_ value: Bool, forKey key: String) {
        set(value as Any, forKey: key)
    }

    public func set(_ value: String, forKey key: String) {
        set(value as Any, forKey: key)
    }

    public func set(_ value: Date, forKey key: String) {
        set(value as Any, forKey: key)
    }

    public func removeValue(forKey key: String) {
        removeObject(forKey: key)
    }
}

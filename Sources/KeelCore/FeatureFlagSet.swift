/// The resolved feature flags: compiled-in defaults with the server's overrides on top.
///
/// A value type, and the *portable* half of the flag mechanism — `KeelClient.FeatureFlags`
/// wraps one of these in `@Observable` for SwiftUI. The lookup rules are:
///
/// - **Fail-open on the default.** A flag the server never mentioned reads as its
///   compiled-in default, so a fresh backend changes nothing.
/// - **Replace, not merge.** Applying a response replaces the whole override set; a flag
///   the server *stops* mentioning reverts to its default instead of sticking at a stale
///   override forever (`docs/ARCHITECTURE.md` §6).
/// - **Unknown names are kept**, not dropped: the server may name a flag this build does
///   not know (configured ahead of a release), and a newer build reading the same set will.
public struct FeatureFlagSet: Sendable, Equatable {
    /// The compiled-in defaults, keyed by flag name. The complete list of flags this build
    /// knows; a flag absent here and absent from the server reads as `false`.
    public var defaults: [String: Bool]

    /// The server's current overrides, applied wholesale by `applying(_:)`.
    public var overrides: [String: Bool]

    public init(defaults: [String: Bool] = [:], overrides: [String: Bool] = [:]) {
        self.defaults = defaults
        self.overrides = overrides
    }

    /// The value of one flag: override if present, else default, else false.
    ///
    /// `false` for a name nobody declared is the conservative end — an undeclared flag is
    /// a typo, and a typo that silently enables something is the worse of the two bugs.
    public subscript(name: String) -> Bool {
        overrides[name] ?? defaults[name] ?? false
    }

    /// This set with the server's `features` section applied — a wholesale replace.
    public func applying(_ features: [String: Bool]) -> FeatureFlagSet {
        FeatureFlagSet(defaults: defaults, overrides: features)
    }

    /// Every name this set can say anything about, for debug UI.
    public var knownNames: [String] {
        Array(Set(defaults.keys).union(overrides.keys)).sorted()
    }
}

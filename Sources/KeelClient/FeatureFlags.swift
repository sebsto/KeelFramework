import KeelCore
public import Observation

/// The app's flag vocabulary: a string-backed enum, one case per flag, each with its
/// compiled-in default.
///
/// ```swift
/// enum AppFlag: String, KeelFlag {
///     case sleepTimer = "sleep_timer"
///     case anniversaryCover = "anniversary_cover"
///
///     var defaultValue: Bool {
///         switch self {
///         case .sleepTimer: true
///         case .anniversaryCover: false
///         }
///     }
/// }
/// ```
///
/// The enum being `CaseIterable` is what makes "every declared flag ships a default"
/// true by construction — `defaultValue` is a required member, so a new case without a
/// decision does not compile.
public protocol KeelFlag: RawRepresentable<String>, CaseIterable, Sendable, Hashable {
    var defaultValue: Bool { get }
}

extension KeelFlag {
    /// The compiled-in defaults for `KeelConfiguration.flagDefaults`, derived rather
    /// than hand-listed so the enum and the wire dictionary cannot drift.
    public static var flagDefaults: [String: Bool] {
        Dictionary(uniqueKeysWithValues: allCases.map { ($0.rawValue, $0.defaultValue) })
    }
}

/// The observable flag store, typed by the app's own `KeelFlag` enum.
///
/// Reads are fail-open by construction: the subscript takes a *case*, so a typo is a
/// compile error rather than a silently-false string, and an absent override reads the
/// case's own default. Server flags this enum does not declare are carried but
/// unreachable through the typed subscript — visible via `unknownServerFlags` for the
/// debug screen, ignored everywhere else.
@Observable
@MainActor
public final class FeatureFlags<Flag: KeelFlag> {
    private var flagSet: FeatureFlagSet

    public init() {
        self.flagSet = FeatureFlagSet(defaults: Flag.flagDefaults)
    }

    public subscript(flag: Flag) -> Bool {
        flagSet[flag.rawValue]
    }

    /// Apply a bootstrap response's `features` section — a wholesale replace, so a flag
    /// the server stops mentioning reverts to its default (`docs/ARCHITECTURE.md` §6).
    public func update(from features: [String: Bool]) {
        flagSet = flagSet.applying(features)
    }

    /// Server flags this build has no case for: configured ahead of a release, or a
    /// name that drifted. For the debug screen; a warning-worthy state, not an error.
    public var unknownServerFlags: [String] {
        let declared = Set(Flag.allCases.map(\.rawValue))
        return flagSet.overrides.keys.filter { !declared.contains($0) }.sorted()
    }
}

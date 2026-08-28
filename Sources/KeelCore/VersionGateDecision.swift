/// What the app should do about the gate the server sent — the client's *entire* reasoning.
///
/// The server already compared versions (`docs/ARCHITECTURE.md` §3): thresholds arrive only
/// when they apply to this build, so evaluation here is presence-checking and precedence,
/// never semver. That is the design's point — the comparison with the edge cases lives on
/// the side a deploy can fix.
///
/// Precedence: maintenance ▸ blocked ▸ soft update ▸ proceed. Maintenance first because it
/// is the operator's explicit "stop asking"; an update prompt underneath it would send the
/// user to the App Store to fix an outage they cannot fix.
public enum VersionGateDecision: Sendable, Equatable {
    /// Nothing to do. Also the answer for no gate at all, and for a response that never
    /// arrived — the gate can only act on what the server actually said.
    case proceed

    /// A dismissible nudge toward `version`.
    case softUpdate(version: String, updateURL: String?)

    /// A blocking screen: this build is below the minimum. `recommendedVersion` may also
    /// be present on the wire; blocking wins.
    case blocked(minimumVersion: String, updateURL: String?)

    /// The operator took the backend down with an explanation.
    case maintenance(Maintenance)

    /// Evaluate a bootstrap gate section. Nil — the section omitted — means proceed.
    public static func evaluate(_ gate: VersionGate?) -> VersionGateDecision {
        guard let gate else { return .proceed }
        if let maintenance = gate.maintenance {
            return .maintenance(maintenance)
        }
        if let minimum = gate.minSupportedVersion {
            return .blocked(minimumVersion: minimum, updateURL: gate.updateURL)
        }
        if let recommended = gate.recommendedVersion {
            return .softUpdate(version: recommended, updateURL: gate.updateURL)
        }
        return .proceed
    }

    /// Whether the app should stop presenting its normal UI.
    public var isBlocking: Bool {
        switch self {
        case .proceed, .softUpdate:
            false
        case .blocked:
            true
        case .maintenance(let maintenance):
            !maintenance.allowsDismissal
        }
    }
}

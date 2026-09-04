/// The `ALIAS_ROUTES` variable — extra paths for the canonical handlers, declared per deployment.
///
/// This is the retrofit affordance (`docs/ARCHITECTURE.md` §3): a shipped client keeps calling
/// the path it was built with while new builds move to `/v1/…`. A legacy `/station` path is the
/// motivating case, including its envelope:
///
/// ```
/// ALIAS_ROUTES="/station=bootstrap.flattened, /usage=stats"
/// ```
///
/// Each entry is `path=target`, where the target is a canonical route name (`bootstrap`, `ping`,
/// `stats`) with an optional `.flattened` suffix on `bootstrap` — the envelope that hoists the
/// `app` payload's keys to the top level, which is the flattened `/station` shape a legacy
/// client expects.
///
/// Deployment configuration rather than remote config, deliberately: the route table is built
/// once at cold start, and a route that appears and disappears with a cache TTL would be a
/// deployment surface nobody can reason about. Same parsing philosophy as
/// ``FeatureFlagsOverride``: a malformed entry is dropped, never fatal, and reported via
/// ``malformedEntries`` so the caller can log what a silently missing route looks like.
public struct AliasRoutes: Sendable, Equatable {
    /// The variable the Lambda reads. The CDK construct sets it from its `aliasRoutes` prop.
    public static let environmentKey = "ALIAS_ROUTES"

    /// No aliases — the normal state, and what an absent or blank variable parses to.
    public static let none = AliasRoutes()

    /// How an alias serialises the canonical response.
    public enum Envelope: Sendable, Equatable {
        /// The canonical shape, byte-identical to the `/v1/…` route.
        case standard

        /// The `app` payload's keys hoisted to the top level beside `features` — the flattened
        /// `/station` shape a legacy client expects. Only meaningful on `bootstrap`, the one
        /// route with an `app` payload.
        case flattened
    }

    /// One declared alias: an extra path serving a canonical route.
    public struct Alias: Sendable, Equatable {
        /// The extra path, exactly as a client requests it — `/station`.
        public var path: String

        public var target: Keel.Route

        public var envelope: Envelope

        public init(path: String, target: Keel.Route, envelope: Envelope = .standard) {
            self.path = path
            self.target = target
            self.envelope = envelope
        }
    }

    /// The declared aliases, in declaration order. A duplicated path keeps the last occurrence,
    /// matching how a shell treats a repeated assignment.
    public let aliases: [Alias]

    /// Entries the parser could not read, verbatim, for the log.
    public let malformedEntries: [String]

    public var isEmpty: Bool { aliases.isEmpty }

    public init(aliases: [Alias] = [], malformedEntries: [String] = []) {
        self.aliases = aliases
        self.malformedEntries = malformedEntries
    }

    /// Parses the variable's value. A nil, empty, or whitespace-only value yields ``none``.
    public init(environmentValue: String?) {
        guard let raw = environmentValue, !Self.trimmed(raw[...]).isEmpty else {
            self.init()
            return
        }

        var parsed: [Alias] = []
        var malformed: [String] = []

        for rawEntry in raw.split(separator: ",") {
            let entry = Self.trimmed(rawEntry)
            guard !entry.isEmpty else { continue }

            let parts = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let alias = Self.alias(path: parts[0], target: parts[1])
            else {
                malformed.append(String(entry))
                continue
            }
            // Last occurrence wins, so a repeated path cannot register two handlers.
            parsed.removeAll { $0.path == alias.path }
            parsed.append(alias)
        }

        self.init(aliases: parsed, malformedEntries: malformed)
    }

    /// One parsed entry, or nil if any part of it is unusable.
    ///
    /// Strict where `FeatureFlagsOverride` is strict and for the same reason inverted: a flag
    /// typo loses one override, but an alias typo loses a *route* — a shipped client's requests
    /// start answering 404 — so nothing questionable is guessed at. A path that does not start
    /// with `/`, a path that shadows a canonical route, an unknown target, and `.flattened` on
    /// anything but `bootstrap` are all malformed rather than "probably meant".
    private static func alias(path rawPath: Substring, target rawTarget: Substring) -> Alias? {
        let path = String(trimmed(rawPath))
        guard path.hasPrefix("/"), path.count > 1 else { return nil }
        guard Keel.Route(rawValue: path) == nil else { return nil }

        let target = trimmed(rawTarget)
        let targetParts = target.split(separator: ".", maxSplits: 1)
        guard let name = targetParts.first, let route = Self.route(named: name) else { return nil }

        switch targetParts.count {
        case 1:
            return Alias(path: path, target: route, envelope: .standard)
        case 2 where targetParts[1] == "flattened" && route == .bootstrap:
            return Alias(path: path, target: route, envelope: .flattened)
        default:
            return nil
        }
    }

    /// The canonical route for a target name — the route's own name, not its path.
    private static func route(named name: Substring) -> Keel.Route? {
        switch name {
        case "bootstrap": .bootstrap
        case "ping": .ping
        case "stats": .stats
        default: nil
        }
    }

    /// Whitespace-trimmed without `CharacterSet`, which `FoundationEssentials` does not have.
    private static func trimmed(_ text: Substring) -> Substring {
        var slice = text
        while let first = slice.first, first.isWhitespace { slice = slice.dropFirst() }
        while let last = slice.last, last.isWhitespace { slice = slice.dropLast() }
        return slice
    }
}

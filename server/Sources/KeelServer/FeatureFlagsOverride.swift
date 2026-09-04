/// The `FEATURE_FLAGS` environment override — flags flipped in seconds, without the table.
///
/// Product configuration belongs in DynamoDB so it can change without a deploy
/// (`docs/ARCHITECTURE.md` §7). This is the one exception, and it exists for two situations that
/// both happen at the worst possible time: the table is unreachable, or a flag has to be off
/// *now* and `aws lambda update-function-configuration` is the fastest tool within reach.
///
/// ```
/// FEATURE_FLAGS="anniversary_cover=false, sleep_timer=1"
/// ```
///
/// The parser keeps the properties that matter:
///
/// - **Names are passed through.** The server keeps no list of known flags, so a flag can be set
///   before or after the build that reads it ships.
/// - **A malformed entry is dropped, never fatal.** A typo in an environment variable must not
///   take `/v1/bootstrap` down — the endpoint that carries the kill switch is the last thing that
///   should fail over a stray comma.
/// - **What was dropped is reported.** `malformedEntries` exists so the caller logs it, because a
///   silently ignored flag is indistinguishable from one that is working.
///
/// It wins over the table by design: a value set here cannot be undone by whatever
/// the config item says. Removing the variable is how you give control back.
public struct FeatureFlagsOverride: Sendable, Equatable {
    /// The variable the Lambda reads. The CDK construct sets it only when asked to.
    public static let environmentKey = "FEATURE_FLAGS"

    /// Nothing overridden — the normal state, and what an absent or blank variable parses to.
    public static let none = FeatureFlagsOverride()

    /// Parsed overrides by flag name. A duplicated name keeps the last occurrence, matching how
    /// a shell would treat a repeated assignment.
    public let values: [String: Bool]

    /// Entries the parser could not read, verbatim, for the log.
    public let malformedEntries: [String]

    public var isEmpty: Bool { values.isEmpty }

    public init(values: [String: Bool] = [:], malformedEntries: [String] = []) {
        self.values = values
        self.malformedEntries = malformedEntries
    }

    /// Parses the variable's value. A nil, empty, or whitespace-only value yields ``none``.
    public init(environmentValue: String?) {
        guard let raw = environmentValue, !Self.trimmed(raw[...]).isEmpty else {
            self.init()
            return
        }

        var parsed: [String: Bool] = [:]
        var malformed: [String] = []

        for rawEntry in raw.split(separator: ",") {
            let entry = Self.trimmed(rawEntry)
            // A trailing comma or a doubled separator is tolerated rather than reported: it is
            // not a mistake anybody needs told about, and reporting it would train the reader to
            // ignore the list that also reports real typos.
            guard !entry.isEmpty else { continue }

            let parts = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else {
                malformed.append(String(entry))
                continue
            }
            let name = Self.trimmed(parts[0])
            guard !name.isEmpty, let value = Self.boolean(parts[1]) else {
                malformed.append(String(entry))
                continue
            }
            parsed[String(name)] = value
        }

        self.init(values: parsed, malformedEntries: malformed)
    }

    /// `base` with these overrides applied on top.
    ///
    /// Per-flag, not wholesale: overriding one flag must not erase the other twenty the config
    /// item declares. An override names a flag the config never mentioned, and that flag is added
    /// — which is how a brand-new flag gets turned on without an item to edit.
    public func applied(to base: [String: Bool]) -> [String: Bool] {
        guard !values.isEmpty else { return base }
        return base.merging(values) { _, override in override }
    }

    /// `true`/`false`/`1`/`0`, case-insensitive, whitespace tolerated. Nil for anything else —
    /// notably `yes`, which is a value people expect to work and which would silently read as
    /// malformed if it were not for the report.
    private static func boolean(_ field: Substring) -> Bool? {
        switch trimmed(field).lowercased() {
        case "true", "1": true
        case "false", "0": false
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

// No Foundation import: these are stdlib types only. Files that do need Foundation use the
// `#if canImport(FoundationEssentials)` form, because this target runs on Linux where
// Foundation is split.

/// Framework-wide constants, the server's copy.
///
/// Deliberately duplicated from `KeelCore.Keel` rather than shared: a client app must not
/// resolve soto and NIO, and the server must not resolve Skip
/// (`docs/adr/0005-two-client-modules.md`). The golden-JSON fixtures read by both test
/// suites are what stop the two copies drifting.
public enum Keel {
    /// Version of the JSON envelope this build emits. Must equal `KeelCore.Keel.schemaVersion`.
    public static let schemaVersion = 1

    /// Version of the framework itself.
    public static let version = "0.1.0"

    /// The canonical route paths. An app mounting its own routes onto the same function adds
    /// them alongside these, not inside this enum.
    public enum Route: String, Sendable, CaseIterable {
        case bootstrap = "/v1/bootstrap"
        case ping = "/v1/ping"
        case stats = "/v1/stats"
    }

    /// How long dated counter partitions live. 400 rather than 365 so a year-over-year
    /// comparison has more than a year of history to compare against
    /// (`docs/adr/0001-single-table-single-function.md`).
    public static let counterTTLDays = 400

    /// DynamoDB attribute names for the single table (`docs/ARCHITECTURE.md` §4). The CDK
    /// package declares the same three in `cdk/lib/contract.ts`.
    public enum Attribute {
        public static let partitionKey = "pk"
        public static let sortKey = "sk"
        public static let timeToLive = "ttl"
        public static let count = "count"
    }
}

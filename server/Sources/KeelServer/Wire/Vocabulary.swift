/// The platform a ping came from.
///
/// A closed set, because the value becomes part of a DynamoDB partition key
/// (`AGG#PLAT#2026-08`). An open string would let a client typo create a partition nothing
/// ever reads and nothing ever cleans up, so the server rejects an unknown value with a 400
/// (`docs/ARCHITECTURE.md` §3).
///
/// Adding a case is a server-side deploy as well as a client one — that friction is the
/// point. `KeelCore.Platform` declares the identical set.
public enum Platform: String, Codable, Sendable, CaseIterable, Equatable {
    case iOS = "ios"
    case iPadOS = "ipados"
    case macOS = "macos"
    case tvOS = "tvos"
    case watchOS = "watchos"
    case visionOS = "visionos"
    case android
    case web
    case windows
    case linux
}

/// Whether the app was paid for at the moment of the ping.
///
/// Closed for the same partition-key reason as `Platform` — these become `AGG#DAU#free`,
/// `AGG#DAU#trial`, `AGG#DAU#paid`.
///
/// `trial` exists separately from `free` because an app with a time-limited trial needs to
/// tell "has not paid" from "is evaluating"; an app without one simply never sends it.
///
/// An app retrofitted onto Keel may have existing data that uses `full` where this says `paid`.
/// Its retrofit maps the old value at the boundary and keeps the old partitions readable rather
/// than migrating them; see `docs/RETROFIT.md`.
public enum LicenseState: String, Codable, Sendable, CaseIterable, Equatable {
    case free
    case trial
    case paid
}

/// A payload-free bootstrap response, for an app that needs no configuration of its own:
/// `BootstrapResponse<Empty>`.
public struct Empty: Codable, Sendable, Equatable {
    public init() {}
}

#if canImport(FoundationEssentials)
public import FoundationEssentials
#else
public import Foundation
#endif

/// Every DynamoDB key the framework reads or writes, in one place.
///
/// This is the load-bearing type of the backend. Nothing else in `KeelServer` builds a key by
/// string interpolation — a handler asks for `CounterSchema.dau(state:)` and gets a partition
/// name, so the table's shape can be reasoned about by reading one file and a rename is a
/// compile error rather than a silently orphaned partition.
///
/// **The key strings are byte-compatible with the format existing telemetry backends already
/// store.** That is deliberate and constrains the naming: `AGG#DAU`, `AGG#VER#2026-08`, and the
/// `2026-08-24` / `2026-08` stamps match that existing format, so such an app can be retrofitted
/// onto Keel without migrating a table or losing history (`docs/RETROFIT.md`). Prefer an awkward
/// name here over a migration there.
///
/// Layout, all in one table with `pk`/`sk` (`docs/ARCHITECTURE.md` §4):
///
/// ```
/// CONFIG#current           │ v1              │ payload            (no ttl)
/// AGG#INSTALLS             │ TOTAL           │ count              (no ttl)
/// AGG#CONVERSIONS          │ TOTAL           │ count              (no ttl)
/// AGG#DAU                  │ 2026-08-24      │ count, ttl +400 d
/// AGG#DAU#<state>          │ 2026-08-24      │ count, ttl +400 d
/// AGG#MAU                  │ 2026-08         │ count, ttl +400 d
/// AGG#MAU#<state>          │ 2026-08         │ count, ttl +400 d
/// AGG#VER#2026-08          │ <appVersion>    │ count, ttl +400 d
/// AGG#OS#2026-08           │ <osVersion>     │ count, ttl +400 d
/// AGG#PLAT#2026-08         │ <platform>      │ count, ttl +400 d
/// AGG#DIM#<name>#2026-08   │ <bucket>        │ count, ttl +400 d
/// ```
///
/// Two shapes appear here, and the difference matters when reading a query:
/// - **Time-series counters** (`AGG#DAU`, `AGG#MAU`) put the *stamp in the sort key*, so one
///   Query with a `sk >= …` bound returns a whole window in a single request.
/// - **Distributions** (`AGG#VER#…`, `AGG#OS#…`, `AGG#PLAT#…`, `AGG#DIM#…`) put the *stamp in
///   the partition key* and the value in the sort key, so one Query returns every version seen
///   in a month. The stamp has to be in the partition here: a distribution's cardinality is
///   unbounded over time but bounded within a month, and monthly partitions are what keep the
///   read from growing forever.
///
/// No GSI, and nothing here is ever `Scan`ned.
public enum CounterSchema {
    // MARK: - Configuration item

    /// The single configuration item: `CONFIG#current` / `v1`.
    ///
    /// One item, versioned by sort key rather than by history. There is no audit trail of past
    /// configs on purpose — this is a live control surface, and `keel config set` on a broken
    /// value is fixed by another `keel config set`, not by a rollback mechanism nobody has
    /// rehearsed.
    public static let configPartitionKey = "CONFIG#current"

    /// Sort key of the config item. Bumped only if the config *item's* own shape changes
    /// incompatibly, which is not the same as `Keel.schemaVersion` (the wire envelope).
    public static let configSortKey = "v1"

    // MARK: - Lifetime totals

    /// `AGG#INSTALLS` / `TOTAL` — never expires.
    public static let installsPartitionKey = "AGG#INSTALLS"

    /// `AGG#CONVERSIONS` / `TOTAL` — never expires.
    public static let conversionsPartitionKey = "AGG#CONVERSIONS"

    /// The sort key of both lifetime totals. A single item per partition; the partition exists
    /// only so the two counters cannot collide.
    public static let totalSortKey = "TOTAL"

    // MARK: - Time series

    /// `AGG#DAU` — all daily actives regardless of license state.
    public static let dauPartitionKey = "AGG#DAU"

    /// `AGG#DAU#free` / `AGG#DAU#trial` / `AGG#DAU#paid`.
    ///
    /// A separate partition per state rather than one item with three attributes: `UpdateItem
    /// ADD` is per-item, and three attributes on one item would serialise every ping of every
    /// state onto a single hot key.
    public static func dau(state: LicenseState) -> String {
        "\(dauPartitionKey)#\(state.rawValue)"
    }

    /// `AGG#MAU`.
    public static let mauPartitionKey = "AGG#MAU"

    /// `AGG#MAU#<state>`.
    public static func mau(state: LicenseState) -> String {
        "\(mauPartitionKey)#\(state.rawValue)"
    }

    // MARK: - Monthly distributions

    /// `AGG#VER#2026-08`, sort key = the app version.
    public static func versions(month: Date) -> String {
        "AGG#VER#\(UTCDate.monthStamp(month))"
    }

    /// `AGG#OS#2026-08`, sort key = the OS version.
    public static func osVersions(month: Date) -> String {
        "AGG#OS#\(UTCDate.monthStamp(month))"
    }

    /// `AGG#PLAT#2026-08`, sort key = the platform's raw value.
    public static func platforms(month: Date) -> String {
        "AGG#PLAT#\(UTCDate.monthStamp(month))"
    }

    /// `AGG#DIM#profiles#2026-08`, sort key = the bucket label.
    ///
    /// `name` must already have been checked against the config's allowlist. Called with an
    /// unvalidated client string, this mints a partition per distinct value — which is why the
    /// allowlist is the one validation `PingHandler` performs before it touches the schema.
    public static func dimension(name: String, month: Date) -> String {
        "AGG#DIM#\(name)#\(UTCDate.monthStamp(month))"
    }

    // MARK: - Sort keys

    /// `2026-08-24` — the sort key of a daily counter.
    public static func daySortKey(_ date: Date) -> String {
        UTCDate.dayStamp(date)
    }

    /// `2026-08` — the sort key of a monthly counter.
    public static func monthSortKey(_ date: Date) -> String {
        UTCDate.monthStamp(date)
    }

    // MARK: - Expiry

    /// The `ttl` attribute for a dated counter: `date` + 400 days, as whole epoch seconds.
    ///
    /// DynamoDB requires epoch **seconds** as a Number; a millisecond value here is accepted
    /// without complaint and expires the item in the year 56000, which is the kind of bug that
    /// surfaces as "the table never stops growing" eighteen months later.
    ///
    /// Lifetime totals get no `ttl` at all rather than a far-future one — an absent attribute is
    /// unambiguous, and a date chosen today as "far enough" eventually arrives.
    public static func expiry(from date: Date, days: Int = Keel.counterTTLDays) -> Int {
        Int(date.timeIntervalSince1970.rounded(.down)) + days * UTCDate.secondsPerDay
    }

    // MARK: - Query windows

    /// The inclusive lower bound for a daily Query: `sk >= dayWindowStart(days:endingAt:)`.
    ///
    /// `days` counts back from and includes `end`, so 30 days ending today spans today and the
    /// 29 before it — the off-by-one that makes a chart's first column a day short.
    public static func dayWindowStart(days: Int, endingAt end: Date) -> String {
        UTCDate.dayStamp(UTCDate.daysAgo(max(days - 1, 0), from: end))
    }

    /// The inclusive lower bound for a monthly Query, counting `months` back from and including
    /// the month containing `end`.
    public static func monthWindowStart(months: Int, endingAt end: Date) -> String {
        UTCDate.monthStamp(UTCDate.monthsAgo(max(months - 1, 0), from: end))
    }

    /// Every day stamp in the window, oldest first — the skeleton the handler zero-fills a
    /// sparse query result onto.
    ///
    /// Built from the calendar rather than from what came back, because a day with no pings is
    /// a `0` the chart needs and not a gap it has to interpret.
    public static func dayStamps(days: Int, endingAt end: Date) -> [String] {
        guard days > 0 else { return [] }
        return (0..<days).reversed().map { UTCDate.dayStamp(UTCDate.daysAgo($0, from: end)) }
    }

    /// Every month stamp in the window, oldest first.
    public static func monthStamps(months: Int, endingAt end: Date) -> [String] {
        guard months > 0 else { return [] }
        return (0..<months).reversed().map { UTCDate.monthStamp(UTCDate.monthsAgo($0, from: end)) }
    }
}

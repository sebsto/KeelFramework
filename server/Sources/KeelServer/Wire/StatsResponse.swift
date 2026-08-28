#if canImport(FoundationEssentials)
public import FoundationEssentials
#else
public import Foundation
#endif

/// The response to `GET /v1/stats`, as the server writes it — every aggregate the table holds.
///
/// Publishing all of it is the mechanism behind the privacy claim, not a feature: a reader can
/// fetch this and see for themselves that the backend stores counters and nothing else
/// (`docs/ARCHITECTURE.md` §9). Anything added to the table that does *not* appear here breaks
/// that, so a new counter comes with a new field in the same change.
///
/// Unlike the bootstrap response, empty collections **are** emitted. A dashboard needs to tell
/// "the window has no data" from "this build of the server has no such series", and a missing
/// key cannot say the first.
public struct StatsResponse: Encodable, Sendable, Equatable {
    public var generatedAt: Date

    /// Lifetime installs. Over-counts reinstalls, by design — see
    /// `docs/adr/0004-client-side-dedup-no-identifier.md`.
    public var installs: Int

    /// Lifetime conversions to a paid state, once per install.
    ///
    /// The ratio is not published. `conversions / installs` has an over-counted denominator, and
    /// emitting the quotient would dress that up as a precise number; two honest counts side by
    /// side let the reader apply their own scepticism. Orthanc made the same call.
    public var conversions: Int

    /// Oldest first, zero-filled across the whole window. The zero-fill happens here rather than
    /// in the dashboard because only the server knows the window's intended length — a gap in
    /// the query result is ambiguous, an explicit `0` is not.
    public var dau: [DailyPoint]

    public var dauByState: [DailyCohortPoint]

    /// Oldest first, zero-filled. The last entry is the current, partial month.
    public var mau: [MonthlyPoint]

    public var mauByState: [MonthlyCohortPoint]

    /// Current month, descending by count.
    public var versions: [VersionShare]

    public var osVersions: [OSShare]

    public var platforms: [PlatformShare]

    /// App-declared distributions, keyed by dimension name.
    ///
    /// Emitted in the bucket order the config declares — **not** by count, unlike the three
    /// series above. A distribution whose axis has been reordered by frequency is misleading.
    /// Buckets never observed are omitted rather than zero-filled: unmeasured is not zero.
    public var dimensions: [String: [BucketShare]]

    public init(
        generatedAt: Date,
        installs: Int = 0,
        conversions: Int = 0,
        dau: [DailyPoint] = [],
        dauByState: [DailyCohortPoint] = [],
        mau: [MonthlyPoint] = [],
        mauByState: [MonthlyCohortPoint] = [],
        versions: [VersionShare] = [],
        osVersions: [OSShare] = [],
        platforms: [PlatformShare] = [],
        dimensions: [String: [BucketShare]] = [:]
    ) {
        self.generatedAt = generatedAt
        self.installs = installs
        self.conversions = conversions
        self.dau = dau
        self.dauByState = dauByState
        self.mau = mau
        self.mauByState = mauByState
        self.versions = versions
        self.osVersions = osVersions
        self.platforms = platforms
        self.dimensions = dimensions
    }

    enum CodingKeys: String, CodingKey {
        case generatedAt, installs, conversions, dau, dauByState, mau, mauByState
        case versions, osVersions, platforms, dimensions
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeISO8601(generatedAt, forKey: .generatedAt)
        try container.encode(installs, forKey: .installs)
        try container.encode(conversions, forKey: .conversions)
        try container.encode(dau, forKey: .dau)
        try container.encode(dauByState, forKey: .dauByState)
        try container.encode(mau, forKey: .mau)
        try container.encode(mauByState, forKey: .mauByState)
        try container.encode(versions, forKey: .versions)
        try container.encode(osVersions, forKey: .osVersions)
        try container.encode(platforms, forKey: .platforms)
        try container.encode(dimensions, forKey: .dimensions)
    }

    // MARK: - Series points

    /// Days and months travel as the stamp strings they are keyed by, not as `Date`. They are
    /// calendar labels, and a dashboard that parsed them into instants and re-rendered them in
    /// the reader's timezone would shift the entire chart by a day west of UTC.
    public struct DailyPoint: Encodable, Sendable, Equatable {
        /// `2026-08-24`, UTC.
        public var date: String
        public var count: Int

        public init(date: String, count: Int) {
            self.date = date
            self.count = count
        }
    }

    /// `2026-08`, UTC.
    public struct MonthlyPoint: Encodable, Sendable, Equatable {
        public var month: String
        public var count: Int

        public init(month: String, count: Int) {
            self.month = month
            self.count = count
        }
    }

    /// One day, split by license state.
    ///
    /// Three fields rather than a map so a state nobody is in reads as `0`. A chart cannot
    /// distinguish an absent key from a zero, and only one of the two is a fact.
    ///
    /// These do not always sum to the matching `dau` entry: they are separate counters, written
    /// by separate `ADD`s, and a partial failure increments one and not the other. The
    /// discrepancy is real and left visible rather than reconciled — a stats page that quietly
    /// adjusts its own numbers is worse than one that is occasionally off by one.
    public struct DailyCohortPoint: Encodable, Sendable, Equatable {
        public var date: String
        public var free: Int
        public var trial: Int
        public var paid: Int

        public init(date: String, free: Int = 0, trial: Int = 0, paid: Int = 0) {
            self.date = date
            self.free = free
            self.trial = trial
            self.paid = paid
        }

        public var total: Int { free + trial + paid }
    }

    /// One month, split by license state.
    public struct MonthlyCohortPoint: Encodable, Sendable, Equatable {
        public var month: String
        public var free: Int
        public var trial: Int
        public var paid: Int

        public init(month: String, free: Int = 0, trial: Int = 0, paid: Int = 0) {
            self.month = month
            self.free = free
            self.trial = trial
            self.paid = paid
        }

        public var total: Int { free + trial + paid }
    }

    // MARK: - Distribution shares

    public struct VersionShare: Encodable, Sendable, Equatable {
        public var version: String
        public var count: Int

        public init(version: String, count: Int) {
            self.version = version
            self.count = count
        }
    }

    public struct OSShare: Encodable, Sendable, Equatable {
        public var osVersion: String
        public var count: Int

        public init(osVersion: String, count: Int) {
            self.osVersion = osVersion
            self.count = count
        }
    }

    /// Emitted as the raw string the table holds rather than a `Platform`, so a value written by
    /// a newer build of the server survives a redeploy of an older one, and so the stats page
    /// never 500s over a partition it does not recognise.
    public struct PlatformShare: Encodable, Sendable, Equatable {
        public var platform: String
        public var count: Int

        public init(platform: String, count: Int) {
            self.platform = platform
            self.count = count
        }

        public init(platform: Platform, count: Int) {
            self.platform = platform.rawValue
            self.count = count
        }
    }

    /// One bucket of one app-declared dimension.
    public struct BucketShare: Encodable, Sendable, Equatable {
        public var bucket: String
        public var count: Int

        public init(bucket: String, count: Int) {
            self.bucket = bucket
            self.count = count
        }
    }
}

#if canImport(FoundationEssentials)
public import FoundationEssentials
#else
public import Foundation
#endif

/// The response to `GET /v1/stats` — **everything** the table holds about usage.
///
/// Completeness is the point, not a convenience: publishing the whole aggregate set is what
/// makes the privacy claim auditable rather than merely stated. Anyone can fetch this and see
/// that it is counters and nothing else (`docs/ARCHITECTURE.md` §9).
///
/// Every collection is present but may be empty, and empty is the honest answer for a backend
/// with no traffic yet. Missing days inside a window are zero-filled server-side so a chart
/// does not have to guess whether a gap means "nobody" or "no data".
///
/// `Decodable` here; the server owns the encoding side.
public struct StatsResponse: Decodable, Sendable, Equatable {
    /// When the server assembled this. The dashboard shows it, because a cached response
    /// (`max-age=300`) can be up to five minutes old and a stats page with no timestamp
    /// invites the reader to assume it is live.
    public var generatedAt: Date

    /// Lifetime first launches — one per install, never expired. The closest thing to a user
    /// count Keel has, and it over-counts: a reinstall is a new install because there is no
    /// identifier to tell them apart (`docs/adr/0004-client-side-dedup-no-identifier.md`).
    public var installs: Int

    /// Lifetime count of installs that reached a paid state, latched once each.
    ///
    /// A conversion *rate* is deliberately not a field: `conversions / installs` divides by an
    /// over-counted denominator, and shipping the quotient would launder that into a number
    /// that looks precise. The dashboard shows both counts side by side instead.
    public var conversions: Int

    /// Daily active installs over the configured window, oldest first, zero-filled.
    public var dau: [DailyPoint]

    /// The same window split by license state. Sums to `dau` for the same date.
    public var dauByState: [DailyCohortPoint]

    /// Monthly active installs, oldest first, zero-filled. The current month is partial.
    public var mau: [MonthlyPoint]

    /// The same months split by license state.
    public var mauByState: [MonthlyCohortPoint]

    /// App-version spread for the current month, descending by count.
    public var versions: [VersionShare]

    /// OS-version spread for the current month, descending by count.
    public var osVersions: [OSShare]

    /// Platform spread for the current month, descending by count.
    public var platforms: [PlatformShare]

    /// App-declared distributions, keyed by dimension name. Empty for an app that declares none.
    ///
    /// Ordered by the bucket order the config declares — **not** by count, unlike the three
    /// series above. `1-2, 3-5, 6-10, 11+` read in count order is a distribution with its axis
    /// shuffled, which is worse than useless.
    ///
    /// Buckets never observed are absent rather than zero: unmeasured is not the same as zero,
    /// and only the config knows which buckets were supposed to exist.
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

    /// Written out so that an older server — one that predates a series added later — still
    /// decodes into an empty series rather than failing the whole page.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try container.decodeISO8601(forKey: .generatedAt)
        installs = try container.decodeIfPresent(Int.self, forKey: .installs) ?? 0
        conversions = try container.decodeIfPresent(Int.self, forKey: .conversions) ?? 0
        dau = try container.decodeIfPresent([DailyPoint].self, forKey: .dau) ?? []
        dauByState =
            try container.decodeIfPresent([DailyCohortPoint].self, forKey: .dauByState) ?? []
        mau = try container.decodeIfPresent([MonthlyPoint].self, forKey: .mau) ?? []
        mauByState =
            try container.decodeIfPresent([MonthlyCohortPoint].self, forKey: .mauByState) ?? []
        versions = try container.decodeIfPresent([VersionShare].self, forKey: .versions) ?? []
        osVersions = try container.decodeIfPresent([OSShare].self, forKey: .osVersions) ?? []
        platforms = try container.decodeIfPresent([PlatformShare].self, forKey: .platforms) ?? []
        dimensions =
            try container.decodeIfPresent([String: [BucketShare]].self, forKey: .dimensions) ?? [:]
    }

    // MARK: - Series points

    /// Dates and months travel as the stamp strings they are keyed by (`2026-08-24`,
    /// `2026-08`), not as `Date`. They *are* calendar labels rather than instants, and a
    /// dashboard that re-formats them through a local timezone would shift the whole chart by
    /// a day for anyone west of UTC.
    public struct DailyPoint: Decodable, Sendable, Equatable {
        /// `2026-08-24`, UTC.
        public var date: String
        public var count: Int

        public init(date: String, count: Int) {
            self.date = date
            self.count = count
        }
    }

    /// `2026-08`, UTC.
    public struct MonthlyPoint: Decodable, Sendable, Equatable {
        public var month: String
        public var count: Int

        public init(month: String, count: Int) {
            self.month = month
            self.count = count
        }
    }

    /// One day, split by license state.
    ///
    /// The three states are separate fields rather than a `[LicenseState: Int]` map so that a
    /// state nobody is in reads as `0` instead of vanishing — a missing key and a zero look
    /// the same to a chart, and only one of them is true.
    public struct DailyCohortPoint: Decodable, Sendable, Equatable {
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

        enum CodingKeys: String, CodingKey {
            case date, free, trial, paid
        }

        /// `trial` is defaulted: apps without a trial never write that partition, and its
        /// absence must not fail the page.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            date = try container.decode(String.self, forKey: .date)
            free = try container.decodeIfPresent(Int.self, forKey: .free) ?? 0
            trial = try container.decodeIfPresent(Int.self, forKey: .trial) ?? 0
            paid = try container.decodeIfPresent(Int.self, forKey: .paid) ?? 0
        }

        public var total: Int { free + trial + paid }
    }

    /// One month, split by license state.
    public struct MonthlyCohortPoint: Decodable, Sendable, Equatable {
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

        enum CodingKeys: String, CodingKey {
            case month, free, trial, paid
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            month = try container.decode(String.self, forKey: .month)
            free = try container.decodeIfPresent(Int.self, forKey: .free) ?? 0
            trial = try container.decodeIfPresent(Int.self, forKey: .trial) ?? 0
            paid = try container.decodeIfPresent(Int.self, forKey: .paid) ?? 0
        }

        public var total: Int { free + trial + paid }
    }

    // MARK: - Distribution shares

    public struct VersionShare: Decodable, Sendable, Equatable {
        public var version: String
        public var count: Int

        public init(version: String, count: Int) {
            self.version = version
            self.count = count
        }
    }

    public struct OSShare: Decodable, Sendable, Equatable {
        public var osVersion: String
        public var count: Int

        public init(osVersion: String, count: Int) {
            self.osVersion = osVersion
            self.count = count
        }
    }

    /// Platform arrives as a `String`, not a `Platform`, because a stats reader must survive a
    /// server that has learned a platform this client has not. The dashboard shows the raw
    /// value; only the ping path needs the closed enum.
    public struct PlatformShare: Decodable, Sendable, Equatable {
        public var platform: String
        public var count: Int

        public init(platform: String, count: Int) {
            self.platform = platform
            self.count = count
        }
    }

    /// One bucket of one app-declared dimension: `{"bucket": "3-5", "count": 42}`.
    public struct BucketShare: Decodable, Sendable, Equatable {
        public var bucket: String
        public var count: Int

        public init(bucket: String, count: Int) {
            self.bucket = bucket
            self.count = count
        }
    }
}

import KeelServer
import Synchronization

#if canImport(FoundationEssentials)
public import FoundationEssentials
#else
public import Foundation
#endif

/// A clock a test moves by hand.
///
/// Every type in `KeelServer` that needs the time takes a `@Sendable () -> Date` rather than
/// calling `Date()`, so the TTL, the ping's day boundary and the maintenance window are all
/// testable without sleeping. This is the other half of that: `clock.callable` is what you hand
/// them, and `advance(days:)` is what makes a month pass in a microsecond.
public final class TestClock: Sendable {
    private let instant: Mutex<Date>

    /// Defaults to 2026-08-24T10:00:00Z — the instant in every example in `docs/ARCHITECTURE.md`,
    /// so a fixture's `generatedAt` and a doc's sample response are the same string.
    public init(_ start: Date = TestClock.default) {
        instant = Mutex(start)
    }

    public static let `default` = UTCDate.date(year: 2026, month: 8, day: 24)
        .addingTimeInterval(10 * 3_600)

    public var now: Date { instant.withLock { $0 } }

    /// Pass this where a `@Sendable () -> Date` is wanted. Reads the clock at call time, so a
    /// handler constructed once still sees every later `advance`.
    public var callable: @Sendable () -> Date {
        // Captures `self`, not the `Mutex` — a `Mutex` is non-copyable and a capture list would
        // try to consume it.
        { self.now }
    }

    public func advance(by seconds: TimeInterval) {
        instant.withLock { $0 = $0.addingTimeInterval(seconds) }
    }

    public func advance(days: Int) {
        advance(by: Double(days) * 86_400)
    }

    public func set(_ date: Date) {
        instant.withLock { $0 = date }
    }

    /// Midnight UTC on a civil date. Built through `UTCDate` rather than a formatter so a test
    /// cannot disagree with the code that produces the sort keys it asserts.
    public func set(year: Int, month: Int, day: Int) {
        set(UTCDate.date(year: year, month: month, day: day))
    }
}

import Testing

@testable import KeelCore

@Suite("Feature flag set")
struct FeatureFlagSetTests {

    static let defaults = ["sleep_timer": true, "anniversary_cover": false]

    @Test("With no overrides, every flag reads its compiled-in default")
    func defaultsApply() {
        let flags = FeatureFlagSet(defaults: Self.defaults)
        #expect(flags["sleep_timer"])
        #expect(!flags["anniversary_cover"])
    }

    @Test("An override wins over the default")
    func overrideWins() {
        let flags = FeatureFlagSet(defaults: Self.defaults)
            .applying(["sleep_timer": false])
        #expect(!flags["sleep_timer"])
    }

    @Test("A flag nobody declared reads false — a typo must not enable anything")
    func undeclaredIsFalse() {
        let flags = FeatureFlagSet(defaults: Self.defaults)
        #expect(!flags["sleep_tmier"])
    }

    @Test("Applying replaces wholesale: a flag the server stops sending reverts")
    func applyingReplaces() {
        let overridden = FeatureFlagSet(defaults: Self.defaults)
            .applying(["sleep_timer": false])
        #expect(!overridden["sleep_timer"])

        // The next response no longer mentions sleep_timer: back to the default, not
        // stuck at the stale override forever.
        let reverted = overridden.applying(["anniversary_cover": true])
        #expect(reverted["sleep_timer"])
        #expect(reverted["anniversary_cover"])
    }

    @Test("A server flag this build does not know is kept and readable")
    func unknownServerFlagIsKept() {
        let flags = FeatureFlagSet(defaults: Self.defaults).applying(["new_flag": true])
        // Configured ahead of the release that reads it — the value is there when a newer
        // build looks, and a debug screen can already show it.
        #expect(flags["new_flag"])
        #expect(flags.knownNames.contains("new_flag"))
    }

    @Test("Known names are the union of both sides, sorted")
    func knownNames() {
        let flags = FeatureFlagSet(defaults: Self.defaults).applying(["extra": true])
        #expect(flags.knownNames == ["anniversary_cover", "extra", "sleep_timer"])
    }
}

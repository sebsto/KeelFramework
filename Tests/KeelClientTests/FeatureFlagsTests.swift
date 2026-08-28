import Testing

@testable import KeelClient

/// The typed store over `FeatureFlagSet` — what an app actually touches.
@Suite("Feature flags store")
@MainActor
struct FeatureFlagsTests {

    enum TestFlag: String, KeelFlag {
        case sleepTimer = "sleep_timer"
        case anniversaryCover = "anniversary_cover"

        var defaultValue: Bool {
            switch self {
            case .sleepTimer: true
            case .anniversaryCover: false
            }
        }
    }

    @Test("Every case reads its declared default before any server contact")
    func defaults() {
        let flags = FeatureFlags<TestFlag>()
        #expect(flags[.sleepTimer])
        #expect(!flags[.anniversaryCover])
    }

    @Test("flagDefaults derives the wire dictionary from the enum")
    func derivedDefaults() {
        #expect(TestFlag.flagDefaults == ["sleep_timer": true, "anniversary_cover": false])
    }

    @Test("An update overrides, and the next update reverts what it stops mentioning")
    func updateAndRevert() {
        let flags = FeatureFlags<TestFlag>()
        flags.update(from: ["sleep_timer": false])
        #expect(!flags[.sleepTimer])

        flags.update(from: ["anniversary_cover": true])
        #expect(flags[.sleepTimer])
        #expect(flags[.anniversaryCover])
    }

    @Test("Server flags with no case are surfaced for the debug screen, nothing else")
    func unknownServerFlags() {
        let flags = FeatureFlags<TestFlag>()
        flags.update(from: ["configured_ahead": true])
        #expect(flags.unknownServerFlags == ["configured_ahead"])
        // The typed subscript cannot even ask for it — that is the point.
    }
}

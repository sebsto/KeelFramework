import Testing

@testable import KeelCore

/// The client half of the constants that are deliberately duplicated across the three
/// artifacts (`docs/ARCHITECTURE.md` §3). `server/Tests/KeelServerTests` asserts the same
/// values, and `cdk/test/contract.test.ts` the TypeScript copy. Phase 1 replaces these with
/// golden-JSON fixtures shared by both Swift suites, which is a stronger pin; until then
/// these three literals are the pin.
@Suite("Wire contract constants")
struct ContractConstantsTests {
    @Test func schemaVersionIsOne() {
        #expect(Keel.schemaVersion == 1)
    }

    @Test func routePathsAreTheCanonicalThree() {
        #expect(Keel.Route.allCases.map(\.rawValue) == ["/v1/bootstrap", "/v1/ping", "/v1/stats"])
    }

    /// Grace-first: a launch must never wait longer than this on Keel
    /// (`docs/ARCHITECTURE.md` §1). Both existing apps use 3 seconds; raising it would
    /// change a user-visible property, so it is asserted rather than merely documented.
    @Test func requestTimeoutIsThreeSeconds() {
        #expect(Keel.requestTimeout == .seconds(3))
    }
}

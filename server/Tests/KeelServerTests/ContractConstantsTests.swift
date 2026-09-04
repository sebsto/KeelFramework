import Testing

@testable import KeelServer

/// The server half of the duplicated constants. These assertions and the identical ones in
/// `Tests/KeelCoreTests/ContractConstantsTests.swift` are what make the duplication safe:
/// the two packages cannot share a target (`docs/adr/0005-two-client-modules.md`), so the
/// literals are held equal by both suites asserting the same numbers.
@Suite("Wire contract constants")
struct ContractConstantsTests {
    @Test func schemaVersionIsOne() {
        #expect(Keel.schemaVersion == 1)
    }

    @Test func routePathsAreTheCanonicalThree() {
        #expect(Keel.Route.allCases.map(\.rawValue) == ["/v1/bootstrap", "/v1/ping", "/v1/stats"])
    }

    /// 400, not 365 (`docs/adr/0001-single-table-single-function.md`). Lowering it silently
    /// truncates the history the dashboard's year-over-year view reads.
    @Test func counterRetentionIs400Days() {
        #expect(Keel.counterTTLDays == 400)
    }

    /// Renaming any of these orphans every existing item — the table is byte-compatible with
    /// the format an existing telemetry backend already stores, which is what makes a retrofit
    /// need no data migration.
    @Test func tableAttributeNamesMatchTheDeployedSchema() {
        #expect(Keel.Attribute.partitionKey == "pk")
        #expect(Keel.Attribute.sortKey == "sk")
        #expect(Keel.Attribute.timeToLive == "ttl")
        #expect(Keel.Attribute.count == "count")
    }
}

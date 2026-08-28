import Testing

@testable import KeelCore

/// The client's whole share of the gate: presence-checking and precedence. If a test here
/// ever needs a version comparison, the design has been violated somewhere.
@Suite("Version gate decision")
struct VersionGateDecisionTests {

    @Test("No gate section means proceed — absence is the signal")
    func noGate() {
        #expect(VersionGateDecision.evaluate(nil) == .proceed)
    }

    @Test("An empty gate also proceeds")
    func emptyGate() {
        #expect(VersionGateDecision.evaluate(VersionGate()) == .proceed)
    }

    @Test("A minimum version present means blocked, with the link")
    func blocked() {
        let decision = VersionGateDecision.evaluate(
            VersionGate(minSupportedVersion: "1.4", updateURL: "https://apps.apple.com/x"))
        #expect(decision == .blocked(minimumVersion: "1.4", updateURL: "https://apps.apple.com/x"))
        #expect(decision.isBlocking)
    }

    @Test("Only a recommendation means a dismissible nudge")
    func softUpdate() {
        let decision = VersionGateDecision.evaluate(VersionGate(recommendedVersion: "2.2"))
        #expect(decision == .softUpdate(version: "2.2", updateURL: nil))
        #expect(!decision.isBlocking)
    }

    @Test("Blocking wins when both thresholds arrive")
    func blockingWins() {
        // The server sends both when the build is below both; the nudge is subsumed.
        let decision = VersionGateDecision.evaluate(
            VersionGate(minSupportedVersion: "1.4", recommendedVersion: "2.2"))
        #expect(decision == .blocked(minimumVersion: "1.4", updateURL: nil))
    }

    @Test("Maintenance wins over everything — no update prompt during an outage")
    func maintenanceWins() {
        let maintenance = Maintenance(message: "Back at 14:00 UTC")
        let decision = VersionGateDecision.evaluate(
            VersionGate(
                minSupportedVersion: "1.4",
                recommendedVersion: "2.2",
                maintenance: maintenance))
        #expect(decision == .maintenance(maintenance))
        #expect(decision.isBlocking)
    }

    @Test("A dismissible maintenance notice does not block")
    func dismissibleMaintenance() {
        let decision = VersionGateDecision.evaluate(
            VersionGate(maintenance: Maintenance(message: "Degraded", allowsDismissal: true)))
        #expect(!decision.isBlocking)
    }
}

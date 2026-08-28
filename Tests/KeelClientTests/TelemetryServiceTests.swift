import Foundation
import KeelClientTesting
import KeelCore
import Testing

@testable import KeelClient

/// The guard order and the persistence order are the design; every test here pins one of
/// them. State persists only after an accepted send, and the user's opt-out beats the
/// server's switch beats the calendar.
@Suite("Telemetry service")
@MainActor
struct TelemetryServiceTests {

    static let now = UTCDate.date(year: 2026, month: 8, day: 24).addingTimeInterval(10 * 3_600)

    private struct Harness {
        let transport: FakeTransport
        let defaults: InMemoryKeyValueStore
        let service: TelemetryService

        @MainActor
        init(
            now: Date = TelemetryServiceTests.now,
            isDemoMode: @escaping @Sendable () -> Bool = { false }
        ) {
            let transport = FakeTransport()
            let defaults = InMemoryKeyValueStore()
            self.transport = transport
            self.defaults = defaults
            self.service = TelemetryService(
                configuration: KeelConfiguration(
                    baseURL: URL(string: "https://api.example.com")!,
                    appVersion: "2.1.0",
                    osVersion: "26.1",
                    platform: .iOS,
                    isDemoMode: isDemoMode,
                    transport: transport,
                    defaults: defaults,
                    now: { now }))
        }

        func acceptPings() async {
            await transport.respond(to: "/v1/ping", body: #"{"ok": true}"#)
        }

        func sentBody() async throws -> [String: Any] {
            let request = try #require(await transport.requests.last)
            let json = try JSONSerialization.jsonObject(with: request.body ?? Data())
            return try #require(json as? [String: Any])
        }
    }

    @Test("A first launch pings with every flag and persists the dedup state")
    func firstLaunch() async throws {
        let harness = Harness()
        await harness.acceptPings()

        await harness.service.run(licenseState: .free)

        let body = try await harness.sentBody()
        #expect(body["firstPingEver"] as? Bool == true)
        #expect(body["firstToday"] as? Bool == true)
        #expect(body["appVersion"] as? String == "2.1.0")
        #expect(body["platform"] as? String == "ios")
        #expect(harness.defaults.date(forKey: TelemetryService.Key.lastPingDate) == Self.now)
        #expect(
            harness.defaults.string(forKey: TelemetryService.Key.lastPingVersion) == "2.1.0")
    }

    @Test("A second launch the same day sends nothing at all")
    func sameDayIsSilent() async throws {
        let harness = Harness()
        await harness.acceptPings()
        harness.defaults.set(
            Self.now.addingTimeInterval(-3_600), forKey: TelemetryService.Key.lastPingDate)
        harness.defaults.set("2.1.0", forKey: TelemetryService.Key.lastPingVersion)

        await harness.service.run(licenseState: .free)
        #expect(await harness.transport.requests.isEmpty)
    }

    @Test("The user's opt-out wins over everything, and absent means enabled")
    func userOptOut() async throws {
        let optedOut = Harness()
        await optedOut.acceptPings()
        optedOut.defaults.set(false, forKey: TelemetryService.Key.isEnabled)
        await optedOut.service.run(licenseState: .free)
        #expect(await optedOut.transport.requests.isEmpty)

        // Absent key: never touched the setting, telemetry is on (docs/PRIVACY.md).
        let untouched = Harness()
        await untouched.acceptPings()
        #expect(untouched.service.isUserEnabled)
        await untouched.service.run(licenseState: .free)
        #expect(await untouched.transport.requests.count == 1)
    }

    @Test("Demo mode sends nothing — App Review expects offline operation")
    func demoMode() async {
        let harness = Harness(isDemoMode: { true })
        await harness.acceptPings()
        await harness.service.run(licenseState: .free)
        #expect(await harness.transport.requests.isEmpty)
    }

    @Test("The server-side kill switch stops the request being made")
    func serverKillSwitch() async {
        let harness = Harness()
        await harness.acceptPings()
        await harness.service.run(
            licenseState: .free, telemetry: TelemetryConfig(isEnabled: false))
        // No request, not an errored one: the client's half of the two-sided switch.
        #expect(await harness.transport.requests.isEmpty)
        #expect(harness.defaults.date(forKey: TelemetryService.Key.lastPingDate) == nil)
    }

    @Test("A rejected ping persists nothing, so tomorrow re-offers the same counts")
    func rejectedPingPersistsNothing() async {
        let harness = Harness()
        await harness.transport.respond(to: "/v1/ping", status: 500, body: "{}")

        await harness.service.run(licenseState: .free)

        #expect(await harness.transport.requests.count == 1)
        // odvpn persists first and silently drops a day on failure; this is the fix.
        #expect(harness.defaults.keys.isEmpty)
    }

    @Test("The paid ratchet latches only on an accepted conversion ping")
    func paidRatchet() async throws {
        let rejected = Harness()
        await rejected.transport.respond(to: "/v1/ping", status: 500, body: "{}")
        await rejected.service.run(licenseState: .paid)
        #expect(rejected.defaults.bool(forKey: TelemetryService.Key.hasPingedPaid) == nil)

        let accepted = Harness()
        await accepted.acceptPings()
        await accepted.service.run(licenseState: .paid)
        let body = try await accepted.sentBody()
        #expect(body["firstPaidLaunch"] as? Bool == true)
        #expect(accepted.defaults.bool(forKey: TelemetryService.Key.hasPingedPaid) == true)
    }

    @Test("A latched ratchet never fires again, even after state changes")
    func latchedRatchetStaysLatched() async throws {
        let harness = Harness()
        await harness.acceptPings()
        harness.defaults.set(true, forKey: TelemetryService.Key.hasPingedPaid)

        await harness.service.run(licenseState: .paid)

        // A refund followed by a re-purchase is not a second conversion.
        let body = try await harness.sentBody()
        #expect(
            body["firstPaidLaunch"] as? Bool == nil || body["firstPaidLaunch"] as? Bool == false)
    }

    @Test("Dimensions the server did not advertise are not sent")
    func dimensionFiltering() async throws {
        let harness = Harness()
        await harness.acceptPings()

        await harness.service.run(
            licenseState: .free,
            dimensions: ["profiles": "3-5", "unadvertised": "x"],
            telemetry: TelemetryConfig(isEnabled: true, dimensions: ["profiles"]))

        let body = try await harness.sentBody()
        let dimensions = try #require(body["dimensions"] as? [String: String])
        #expect(dimensions == ["profiles": "3-5"])
    }

    @Test("No advertised constraint means the app's dimensions go through unfiltered")
    func noConstraintSendsAll() async throws {
        let harness = Harness()
        await harness.acceptPings()

        await harness.service.run(
            licenseState: .free,
            dimensions: ["profiles": "3-5"],
            telemetry: .default)

        let body = try await harness.sentBody()
        #expect((body["dimensions"] as? [String: String]) == ["profiles": "3-5"])
    }

    @Test("An upgrade pings on a day that would otherwise be silent")
    func upgradePings() async throws {
        let harness = Harness()
        await harness.acceptPings()
        harness.defaults.set(
            Self.now.addingTimeInterval(-3_600), forKey: TelemetryService.Key.lastPingDate)
        harness.defaults.set("2.0.0", forKey: TelemetryService.Key.lastPingVersion)

        await harness.service.run(licenseState: .free)

        let body = try await harness.sentBody()
        #expect(body["firstThisVersion"] as? Bool == true)
        #expect(body["firstToday"] as? Bool == nil || body["firstToday"] as? Bool == false)
        #expect(
            harness.defaults.string(forKey: TelemetryService.Key.lastPingVersion) == "2.1.0")
    }

    @Test("setUserEnabled writes the same key the toggle and the guard read")
    func settingRoundTrip() {
        let harness = Harness()
        harness.service.setUserEnabled(false)
        #expect(!harness.service.isUserEnabled)
        harness.service.setUserEnabled(true)
        #expect(harness.service.isUserEnabled)
    }
}

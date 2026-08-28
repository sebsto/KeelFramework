import Foundation
import Testing

@testable import KeelCore

/// The client half of the contract check: every response fixture must decode, and the one
/// request the client sends must encode to exactly its fixture.
///
/// `KeelServerTests` runs the mirror of this against the same files — it produces what this
/// consumes and consumes what this produces. Neither suite alone would catch a field renamed in
/// one package and not the other.
@Suite("Golden fixtures, client side")
struct GoldenFixtureTests {

    /// The app-specific payload from `bootstrap-full.json`, decoded the way a real app would:
    /// into its own type, not `JSONValue`.
    struct StationConfig: Decodable, Sendable, Equatable {
        var streamURL: String
        var bitrate: Int
        var genres: [String]
        var sleepTimerDefaultMinutes: Int
    }

    // MARK: - Bootstrap

    @Test("A minimal bootstrap response decodes, defaulting every absent section")
    func minimalBootstrapDecodes() throws {
        let response = try Fixture.decode(
            BootstrapResponse<Empty>.self, from: "bootstrap-minimal.json")

        #expect(response.schemaVersion == Keel.schemaVersion)
        #expect(response.generatedAt == UTCDate.date(fromISO8601: "2026-08-24T10:00:00Z"))
        // The point of the fixture: absent sections mean "no opinion", so the client keeps its
        // compiled-in defaults instead of switching everything off.
        #expect(response.features.isEmpty)
        #expect(response.urls.isEmpty)
        #expect(response.gate == nil)
        #expect(response.app == nil)
        #expect(response.telemetry == .default)
    }

    @Test("A full bootstrap response decodes every section")
    func fullBootstrapDecodes() throws {
        let response = try Fixture.decode(
            BootstrapResponse<StationConfig>.self, from: "bootstrap-full.json")

        #expect(response.features == ["sleep_timer": true, "anniversary_cover": false])
        #expect(response.urls[KeelURL.website] == "https://example.com")
        #expect(response.urls[KeelURL.donation] == "https://example.com/donate")

        let gate = try #require(response.gate)
        #expect(gate.minSupportedVersion == "1.4.0")
        #expect(gate.recommendedVersion == "2.2.0")
        #expect(gate.updateURL == "https://apps.apple.com/app/id1234567890")

        let maintenance = try #require(gate.maintenance)
        #expect(maintenance.message == "Scheduled maintenance. Streaming is unaffected.")
        #expect(maintenance.until == UTCDate.date(fromISO8601: "2026-08-24T12:30:00Z"))
        #expect(maintenance.allowsDismissal)

        #expect(response.telemetry.isEnabled)
        #expect(response.telemetry.dimensions == ["profiles"])

        let app = try #require(response.app)
        #expect(app.streamURL == "https://stream.example.com/live.aac")
        #expect(app.bitrate == 128)
        #expect(app.genres == ["ambient", "downtempo"])
    }

    @Test("The app payload also decodes as opaque JSON, distinguishing null from absent")
    func appPayloadDecodesAsJSONValue() throws {
        let response = try Fixture.decode(
            BootstrapResponse<JSONValue>.self, from: "bootstrap-full.json")
        let app = try #require(response.app)

        // An integer stays an integer, so `keel config set` does not rewrite the app's own
        // numbers as `128.0` every time it reads and writes the item back.
        #expect(app["bitrate"] == JSONValue.int(128))
        #expect(app["genres"]?.array?.count == 2)
        // An explicit null and a missing key are different answers: "the server has no artwork
        // fallback" versus "this server does not know about artwork fallbacks".
        #expect(app["artworkFallback"] == JSONValue.null)
        #expect(app["nothing"] == nil)
    }

    @Test("A fractional number stays fractional; a fraction-free one is normalised to an integer")
    func numberNormalisation() throws {
        let data = Data(#"{"a":3,"b":3.0,"c":3.5}"#.utf8)
        let value = try WireJSON.decoder().decode(JSONValue.self, from: data)
        #expect(value["a"] == JSONValue.int(3))
        // `3.0` becomes `.int(3)`: `JSONDecoder` accepts a fraction-free number as an `Int` and
        // `Decodable` cannot see how it was spelled. JSON has one number type, so nothing is lost.
        #expect(value["b"] == JSONValue.int(3))
        #expect(value["c"] == JSONValue.double(3.5))
        // And `.int` still refuses to round a real fraction away.
        #expect(value["c"]?.int == nil)
    }

    @Test("The server can switch telemetry off")
    func telemetryDisabledDecodes() throws {
        let response = try Fixture.decode(
            BootstrapResponse<Empty>.self, from: "bootstrap-telemetry-disabled.json")
        #expect(response.telemetry.isEnabled == false)
        #expect(response.telemetry == .disabled)
    }

    @Test("An absent telemetry section fails open rather than silently stopping collection")
    func telemetryFailsOpen() throws {
        let response = try Fixture.decode(
            BootstrapResponse<Empty>.self, from: "bootstrap-minimal.json")
        #expect(response.telemetry.isEnabled)
    }

    @Test("An unknown top-level key is ignored, so a newer server does not break this build")
    func unknownKeysAreIgnored() throws {
        var object = try #require(Fixture.json("bootstrap-minimal.json").object)
        object["experiments"] = .object(["cohort": .string("b")])
        let data = try WireJSON.encoder().encode(JSONValue.object(object))

        let response = try WireJSON.decoder().decode(BootstrapResponse<Empty>.self, from: data)
        #expect(response.schemaVersion == 1)
    }

    @Test("A malformed timestamp is a decoding failure, not a silent zero date")
    func malformedTimestampThrows() throws {
        var object = try #require(Fixture.json("bootstrap-minimal.json").object)
        object["generatedAt"] = .string("24/08/2026")
        let data = try WireJSON.encoder().encode(JSONValue.object(object))

        #expect(throws: DecodingError.self) {
            try WireJSON.decoder().decode(BootstrapResponse<Empty>.self, from: data)
        }
    }

    // MARK: - Ping

    @Test("A first-launch ping encodes to its fixture exactly")
    func firstLaunchPingEncodes() throws {
        let request = PingRequest(
            firstPingEver: true,
            firstToday: true,
            firstThisMonth: true,
            firstThisVersion: true,
            firstPaidLaunch: false,
            appVersion: "2.1.0",
            osVersion: "26.1",
            platform: .iOS,
            licenseState: .free,
            dimensions: ["profiles": "3-5"]
        )
        #expect(try Fixture.canonical(request) == Fixture.json("ping-first-launch.json"))
    }

    @Test("A returning-user ping omits dimensions rather than sending an empty object")
    func returningPingEncodes() throws {
        let request = PingRequest(
            firstPingEver: false,
            firstToday: true,
            firstThisMonth: false,
            firstThisVersion: false,
            firstPaidLaunch: false,
            appVersion: "2.1.0",
            osVersion: "26.1",
            platform: .macOS,
            licenseState: .paid
        )
        #expect(try Fixture.canonical(request) == Fixture.json("ping-returning.json"))

        let object = try #require(Fixture.json("ping-returning.json").object)
        #expect(object["dimensions"] == nil)
    }

    @Test("An empty dimensions dictionary is normalised to nil at init")
    func emptyDimensionsBecomeNil() {
        let request = PingRequest(
            firstPingEver: false, firstToday: true, firstThisMonth: false,
            firstThisVersion: false, firstPaidLaunch: false,
            appVersion: "1.0", osVersion: "26.1", platform: .iOS, licenseState: .free,
            dimensions: [:])
        #expect(request.dimensions == nil)
    }

    @Test("A ping that would move no counter reports itself as a no-op")
    func noOpPingIsDetected() {
        let nothingToSay = PingRequest(
            firstPingEver: false, firstToday: false, firstThisMonth: false,
            firstThisVersion: false, firstPaidLaunch: false,
            appVersion: "1.0", osVersion: "26.1", platform: .iOS, licenseState: .free)
        #expect(nothingToSay.isNoOp)

        // One flag is enough to be worth a request. This is what makes the second and every
        // later launch of a day cost nothing at all.
        let upgraded = PingRequest(
            firstPingEver: false, firstToday: false, firstThisMonth: false,
            firstThisVersion: true, firstPaidLaunch: false,
            appVersion: "1.0", osVersion: "26.1", platform: .iOS, licenseState: .free)
        #expect(!upgraded.isNoOp)
    }

    @Test("The ping carries nothing that could identify a device")
    func pingCarriesNoIdentifier() throws {
        // Structural, not stylistic: the privacy claim in docs/PRIVACY.md rests on the field
        // list, so this test fails the moment someone adds a field the policy does not cover.
        let keys = try Set(#require(Fixture.json("ping-first-launch.json").object).keys)
        #expect(
            keys == [
                "firstPingEver", "firstToday", "firstThisMonth", "firstThisVersion",
                "firstPaidLaunch", "appVersion", "osVersion", "platform", "licenseState",
                "dimensions",
            ])
    }

    // MARK: - Stats

    @Test("An empty stats response decodes to empty series, not to missing ones")
    func emptyStatsDecodes() throws {
        let stats = try Fixture.decode(StatsResponse.self, from: "stats-empty.json")

        #expect(stats.installs == 0)
        #expect(stats.conversions == 0)
        #expect(stats.dau.isEmpty)
        #expect(stats.dauByState.isEmpty)
        #expect(stats.mau.isEmpty)
        #expect(stats.versions.isEmpty)
        #expect(stats.platforms.isEmpty)
        #expect(stats.dimensions.isEmpty)
    }

    @Test("A populated stats response decodes every series")
    func populatedStatsDecodes() throws {
        let stats = try Fixture.decode(StatsResponse.self, from: "stats-populated.json")

        #expect(stats.installs == 4_821)
        #expect(stats.conversions == 613)

        #expect(stats.dau.map(\.date) == ["2026-08-22", "2026-08-23", "2026-08-24"])
        // The zero-filled day is a value, not a gap — that is the whole reason the server fills
        // it rather than leaving the dashboard to guess.
        #expect(stats.dau[1].count == 0)

        #expect(stats.dauByState.first?.free == 260)
        #expect(stats.dauByState.first?.trial == 19)
        #expect(stats.dauByState.first?.paid == 62)
        #expect(stats.dauByState.first?.total == 341)
        #expect(stats.dauByState.first?.total == stats.dau.first?.count)

        #expect(stats.mau.map(\.month) == ["2026-07", "2026-08"])
        #expect(stats.mauByState.last?.paid == 313)

        #expect(stats.versions.first?.version == "2.1.0")
        #expect(stats.osVersions.first?.osVersion == "26.1")
        #expect(stats.platforms.first?.platform == "ios")
        #expect(stats.dimensions["profiles"]?.map(\.bucket) == ["1-2", "3-5", "6-10", "11+"])
        #expect(stats.dimensions["profiles"]?.first?.count == 902)
    }

    @Test("A cohort point missing trial reads as zero, for apps that have no trial")
    func cohortWithoutTrialDecodes() throws {
        let data = Data(#"{"date":"2026-08-24","free":10,"paid":2}"#.utf8)
        let point = try WireJSON.decoder().decode(
            StatsResponse.DailyCohortPoint.self, from: data)
        #expect(point.trial == 0)
        #expect(point.total == 12)
    }

    @Test("A platform this build has never heard of does not break the stats page")
    func unknownPlatformInStatsDecodes() throws {
        // `platforms[].platform` is a String, not a Platform, precisely so that a server which
        // has learned a new platform does not 500 an older client's dashboard.
        let data = Data(#"{"platform":"fridgeos","count":3}"#.utf8)
        let share = try WireJSON.decoder().decode(StatsResponse.PlatformShare.self, from: data)
        #expect(share.platform == "fridgeos")
    }
}

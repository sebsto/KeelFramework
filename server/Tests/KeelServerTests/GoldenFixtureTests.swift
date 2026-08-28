import Foundation
import Testing

@testable import KeelServer

/// The server half of the contract check: every response the server emits must equal its
/// fixture, and every request fixture must decode.
///
/// The exact mirror of `KeelCoreTests.GoldenFixtureTests` — this suite produces what that one
/// consumes and vice versa. That crossing is the point: a field renamed in one package and
/// forgotten in the other fails here, which is the only automated protection the duplicated wire
/// types have (`docs/adr/0005-two-client-modules.md`).
@Suite("Golden fixtures, server side")
struct GoldenFixtureTests {

    /// `2026-08-24T10:00:00Z`. Nothing in these tests reads a clock.
    static let generatedAt = UTCDate.date(year: 2026, month: 8, day: 24)
        .addingTimeInterval(10 * 3_600)

    // MARK: - Bootstrap

    @Test("A minimal bootstrap response encodes to its fixture, omitting empty sections")
    func minimalBootstrapEncodes() throws {
        let response = BootstrapResponse<JSONValue>(generatedAt: Self.generatedAt)
        #expect(try Fixture.canonical(response) == Fixture.json("bootstrap-minimal.json"))
    }

    @Test("An unconfigured server still states the telemetry flag")
    func minimalBootstrapStatesTelemetry() throws {
        // Always encoded, even at its default: an operator reading a response should see the
        // state of the ping kill switch rather than have to know that absence means "on".
        let object = try #require(Fixture.json("bootstrap-minimal.json").object)
        #expect(object["telemetry"] == JSONValue.object(["enabled": .bool(true)]))
        #expect(object["features"] == nil)
        #expect(object["urls"] == nil)
        #expect(object["gate"] == nil)
        #expect(object["app"] == nil)
    }

    @Test("A full bootstrap response encodes to its fixture")
    func fullBootstrapEncodes() throws {
        let response = BootstrapResponse<JSONValue>(
            generatedAt: Self.generatedAt,
            features: ["sleep_timer": true, "anniversary_cover": false],
            gate: VersionGate(
                minSupportedVersion: "1.4.0",
                recommendedVersion: "2.2.0",
                updateURL: "https://apps.apple.com/app/id1234567890",
                maintenance: Maintenance(
                    message: "Scheduled maintenance. Streaming is unaffected.",
                    until: UTCDate.date(year: 2026, month: 8, day: 24)
                        .addingTimeInterval(12 * 3_600 + 30 * 60),
                    allowsDismissal: true)),
            telemetry: TelemetryConfig(isEnabled: true, dimensions: ["profiles"]),
            urls: [
                KeelURL.website: "https://example.com",
                KeelURL.privacy: "https://example.com/privacy",
                KeelURL.support: "mailto:support@example.com",
                KeelURL.donation: "https://example.com/donate",
            ],
            app: .object([
                "streamURL": .string("https://stream.example.com/live.aac"),
                "bitrate": .int(128),
                "genres": .array([.string("ambient"), .string("downtempo")]),
                "sleepTimerDefaultMinutes": .int(30),
                "artworkFallback": .null,
            ])
        )
        #expect(try Fixture.canonical(response) == Fixture.json("bootstrap-full.json"))
    }

    @Test("The telemetry kill switch encodes to its fixture")
    func telemetryDisabledEncodes() throws {
        let response = BootstrapResponse<JSONValue>(
            generatedAt: Self.generatedAt, telemetry: .disabled)
        #expect(
            try Fixture.canonical(response) == Fixture.json("bootstrap-telemetry-disabled.json"))
    }

    @Test("An app payload round-trips through JSONValue unchanged")
    func appPayloadRoundTrips() throws {
        // The framework never understands the `app` section, so the only correctness property it
        // has is that what comes out equals what went in — including `128` staying an integer.
        let source = try #require(Fixture.json("bootstrap-full.json").object?["app"])
        let response = BootstrapResponse<JSONValue>(generatedAt: Self.generatedAt, app: source)
        let encoded = try Fixture.canonical(response)
        #expect(encoded.object?["app"] == source)
    }

    @Test("An unset gate is omitted rather than encoded empty")
    func emptyGateIsOmitted() throws {
        #expect(VersionGate().isEmpty)
        #expect(!VersionGate(recommendedVersion: "2.2.0").isEmpty)

        let response = BootstrapResponse<JSONValue>(generatedAt: Self.generatedAt)
        #expect(try Fixture.canonical(response).object?["gate"] == nil)
    }

    @Test("Timestamps are encoded as ISO 8601 strings, never as numbers")
    func timestampsAreStrings() throws {
        // `Date`'s own Codable conformance writes a Double. A `generatedAt` of 1787911200 is
        // valid JSON, unreadable in a log, and would break every hand-written client.
        let response = BootstrapResponse<JSONValue>(generatedAt: Self.generatedAt)
        #expect(
            try Fixture.canonical(response).object?["generatedAt"]
                == JSONValue.string("2026-08-24T10:00:00Z"))
    }

    // MARK: - Ping

    @Test("A first-launch ping decodes with every flag and its dimensions")
    func firstLaunchPingDecodes() throws {
        let request = try Fixture.decode(PingRequest.self, from: "ping-first-launch.json")

        #expect(request.firstPingEver)
        #expect(request.firstToday)
        #expect(request.firstThisMonth)
        #expect(request.firstThisVersion)
        #expect(!request.firstPaidLaunch)
        #expect(request.appVersion == "2.1.0")
        #expect(request.osVersion == "26.1")
        #expect(request.platform == .iOS)
        #expect(request.licenseState == .free)
        #expect(request.dimensions == ["profiles": "3-5"])
        #expect(!request.isNoOp)
    }

    @Test("A returning-user ping decodes, with absent dimensions meaning none")
    func returningPingDecodes() throws {
        let request = try Fixture.decode(PingRequest.self, from: "ping-returning.json")

        #expect(!request.firstPingEver)
        #expect(request.firstToday)
        #expect(request.platform == .macOS)
        #expect(request.licenseState == .paid)
        // Absent, not null, not `{}` — and the server must not have to tell those apart.
        #expect(request.dimensions.isEmpty)
    }

    @Test("A body with only the required fields decodes, for a hand-written or retrofitted client")
    func minimalPingBodyDecodes() throws {
        let data = Data(
            #"{"appVersion":"1.0","osVersion":"26.1","platform":"ios","licenseState":"free"}"#
                .utf8)
        let request = try WireJSON.decoder().decode(PingRequest.self, from: data)
        #expect(request.isNoOp)
        #expect(request.dimensions.isEmpty)
    }

    @Test("An unknown platform is rejected rather than written as a new partition")
    func unknownPlatformIsRejected() throws {
        // A closed enum on the way in is what stops a client typo minting an `AGG#PLAT#…`
        // partition that nothing reads and the TTL never reaches.
        let data = Data(
            #"{"appVersion":"1.0","osVersion":"26.1","platform":"fridgeos","licenseState":"free"}"#
                .utf8)
        #expect(throws: DecodingError.self) {
            try WireJSON.decoder().decode(PingRequest.self, from: data)
        }
    }

    @Test("An unknown license state is rejected for the same reason")
    func unknownLicenseStateIsRejected() throws {
        let data = Data(
            #"{"appVersion":"1.0","osVersion":"26.1","platform":"ios","licenseState":"full"}"#
                .utf8)
        // Note "full": Orthanc's existing wire value. Its retrofit has to map it, which is
        // exactly the kind of thing a closed enum surfaces at the boundary instead of writing
        // a second, parallel set of cohort partitions.
        #expect(throws: DecodingError.self) {
            try WireJSON.decoder().decode(PingRequest.self, from: data)
        }
    }

    @Test("A body missing a required field is rejected")
    func missingRequiredFieldIsRejected() throws {
        let data = Data(#"{"appVersion":"1.0","platform":"ios","licenseState":"free"}"#.utf8)
        #expect(throws: DecodingError.self) {
            try WireJSON.decoder().decode(PingRequest.self, from: data)
        }
    }

    @Test("The ack says nothing but ok")
    func ackIsMinimal() throws {
        #expect(try Fixture.canonical(PingAck()) == JSONValue.object(["ok": .bool(true)]))
    }

    // MARK: - Stats

    @Test("An empty stats response encodes every series as an empty one")
    func emptyStatsEncodes() throws {
        // Emitted, not omitted: a dashboard has to tell "no data in the window" from "this
        // server has no such series", and a missing key cannot say the first.
        let stats = StatsResponse(generatedAt: Self.generatedAt)
        #expect(try Fixture.canonical(stats) == Fixture.json("stats-empty.json"))
    }

    @Test("A populated stats response encodes to its fixture")
    func populatedStatsEncodes() throws {
        let stats = StatsResponse(
            generatedAt: Self.generatedAt,
            installs: 4_821,
            conversions: 613,
            dau: [
                .init(date: "2026-08-22", count: 341),
                .init(date: "2026-08-23", count: 0),
                .init(date: "2026-08-24", count: 298),
            ],
            dauByState: [
                .init(date: "2026-08-22", free: 260, trial: 19, paid: 62),
                .init(date: "2026-08-23", free: 0, trial: 0, paid: 0),
                .init(date: "2026-08-24", free: 221, trial: 14, paid: 63),
            ],
            mau: [
                .init(month: "2026-07", count: 2_104),
                .init(month: "2026-08", count: 1_877),
            ],
            mauByState: [
                .init(month: "2026-07", free: 1_690, trial: 87, paid: 327),
                .init(month: "2026-08", free: 1_502, trial: 62, paid: 313),
            ],
            versions: [
                .init(version: "2.1.0", count: 1_502),
                .init(version: "2.0.3", count: 288),
                .init(version: "1.4.0", count: 87),
            ],
            osVersions: [
                .init(osVersion: "26.1", count: 1_344),
                .init(osVersion: "26.0", count: 402),
                .init(osVersion: "18.6", count: 131),
            ],
            platforms: [
                .init(platform: Platform.iOS, count: 1_401),
                .init(platform: Platform.macOS, count: 376),
                .init(platform: Platform.tvOS, count: 100),
            ],
            dimensions: [
                "profiles": [
                    .init(bucket: "1-2", count: 902),
                    .init(bucket: "3-5", count: 617),
                    .init(bucket: "6-10", count: 254),
                    .init(bucket: "11+", count: 104),
                ]
            ]
        )
        #expect(try Fixture.canonical(stats) == Fixture.json("stats-populated.json"))
    }

    @Test("Series order is preserved, because the chart reads it as given")
    func seriesOrderIsPreserved() throws {
        let encoded = try Fixture.canonical(
            StatsResponse(
                generatedAt: Self.generatedAt,
                dau: [
                    .init(date: "2026-08-22", count: 1),
                    .init(date: "2026-08-23", count: 2),
                ]))
        // JSON arrays are ordered and JSON objects are not, which is why every series here is
        // an array and `dimensions` is the only map.
        #expect(
            encoded.object?["dau"]?.array?.first?.object?["date"]
                == JSONValue.string("2026-08-22"))
    }

    @Test("The published stats cover every counter the schema writes")
    func statsPublishEveryCounter() throws {
        // The privacy claim in docs/PRIVACY.md is "everything collected is published at
        // /v1/stats". This test is that claim: a counter added to the table without a
        // corresponding series here breaks it, and breaks this.
        let published = try Set(#require(Fixture.json("stats-populated.json").object).keys)
        #expect(
            published == [
                "generatedAt", "installs", "conversions", "dau", "dauByState", "mau",
                "mauByState", "versions", "osVersions", "platforms", "dimensions",
            ])
    }
}

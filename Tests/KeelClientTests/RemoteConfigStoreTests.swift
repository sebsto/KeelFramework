import Foundation
import KeelClientTesting
import KeelCore
import Testing

@testable import KeelClient

/// The three-tier chain is the whole type: network ▸ disk cache ▸ compiled-in defaults,
/// each tier only ever improving on the one below.
@Suite("Remote config store")
@MainActor
struct RemoteConfigStoreTests {

    struct AppConfig: Decodable, Sendable, Equatable {
        var streamURL: String
    }

    static let goodBody = """
        {"schemaVersion": 1, "generatedAt": "2026-08-24T10:00:00Z",
         "features": {"sleep_timer": false},
         "telemetry": {"enabled": true},
         "urls": {"privacy": "https://example.com/privacy"},
         "app": {"streamURL": "https://audio.example.com/x"}}
        """

    /// A fresh cache directory per test, so no test reads another's disk tier.
    private static func makeConfiguration(
        transport: FakeTransport,
        cacheDirectory: URL
    ) -> KeelConfiguration {
        KeelConfiguration(
            baseURL: URL(string: "https://api.example.com")!,
            flagDefaults: ["sleep_timer": true, "extra": false],
            cacheDirectory: cacheDirectory,
            appVersion: "2.1.0",
            osVersion: "26.1",
            platform: .iOS,
            transport: transport)
    }

    private static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("keel-tests-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("A successful fetch publishes the network tier and applies the flags")
    func networkTier() async throws {
        let transport = FakeTransport()
        await transport.respond(to: "/v1/bootstrap", body: Self.goodBody)
        let store = RemoteConfigStore<AppConfig>(
            configuration: Self.makeConfiguration(
                transport: transport, cacheDirectory: Self.temporaryDirectory()))

        await store.bootstrap()

        #expect(store.source == .network)
        #expect(store.app == AppConfig(streamURL: "https://audio.example.com/x"))
        // Override beats default; the un-mentioned flag keeps its default.
        #expect(!store.flags["sleep_timer"])
        #expect(!store.flags["extra"])
        #expect(store.url("privacy") == URL(string: "https://example.com/privacy"))
    }

    @Test("Before anything resolves, everything reads as compiled-in defaults")
    func defaultTier() {
        let store = RemoteConfigStore<AppConfig>(
            configuration: Self.makeConfiguration(
                transport: FakeTransport(), cacheDirectory: Self.temporaryDirectory()))

        #expect(store.source == .none)
        #expect(store.response == nil)
        #expect(store.flags["sleep_timer"])
        #expect(store.gateDecision == .proceed)
        #expect(store.telemetry == .default)
        #expect(store.app == nil)
    }

    @Test("The next launch serves yesterday's response from disk before the network answers")
    func diskTier() async throws {
        let cacheDirectory = Self.temporaryDirectory()

        // First launch: network works, cache written.
        let online = FakeTransport()
        await online.respond(to: "/v1/bootstrap", body: Self.goodBody)
        let firstLaunch = RemoteConfigStore<AppConfig>(
            configuration: Self.makeConfiguration(
                transport: online, cacheDirectory: cacheDirectory))
        await firstLaunch.bootstrap()
        #expect(firstLaunch.source == .network)

        // Second launch: offline. The cache is what stands between the user and defaults.
        let offline = FakeTransport()
        await offline.hang(on: "/v1/bootstrap")
        let secondLaunch = RemoteConfigStore<AppConfig>(
            configuration: Self.makeConfiguration(
                transport: offline, cacheDirectory: cacheDirectory))
        await secondLaunch.bootstrap()

        #expect(secondLaunch.source == .diskCache)
        #expect(!secondLaunch.flags["sleep_timer"])
        #expect(secondLaunch.app == AppConfig(streamURL: "https://audio.example.com/x"))
    }

    @Test("A failed refresh never downgrades the tier already published")
    func failedRefreshKeepsTier() async throws {
        let transport = FakeTransport()
        await transport.respond(to: "/v1/bootstrap", body: Self.goodBody)
        let store = RemoteConfigStore<AppConfig>(
            configuration: Self.makeConfiguration(
                transport: transport, cacheDirectory: Self.temporaryDirectory()))
        await store.bootstrap()

        await transport.respond(to: "/v1/bootstrap", status: 500, body: "{}")
        await store.refresh()

        // A stale config beats no config, and beats an error even more.
        #expect(store.source == .network)
        #expect(store.app != nil)
    }

    @Test("An unreadable cache file falls through to defaults and is deleted")
    func corruptCache() async throws {
        let cacheDirectory = Self.temporaryDirectory()
        try FileManager.default.createDirectory(
            at: cacheDirectory, withIntermediateDirectories: true)
        let cacheFile = cacheDirectory.appendingPathComponent("bootstrap.json")
        try Data("not json".utf8).write(to: cacheFile)

        let offline = FakeTransport()
        await offline.hang(on: "/v1/bootstrap")
        let store = RemoteConfigStore<AppConfig>(
            configuration: Self.makeConfiguration(
                transport: offline, cacheDirectory: cacheDirectory))
        await store.bootstrap()

        #expect(store.source == .none)
        // Deleted, so it is not re-parsed on every future launch.
        #expect(!FileManager.default.fileExists(atPath: cacheFile.path))
    }

    @Test("The gate decision flows from the response")
    func gateFlows() async throws {
        let transport = FakeTransport()
        await transport.respond(
            to: "/v1/bootstrap",
            body: """
                {"schemaVersion": 1, "generatedAt": "2026-08-24T10:00:00Z",
                 "telemetry": {"enabled": true},
                 "gate": {"minSupportedVersion": "3.0", "updateURL": "https://apps.apple.com/x"}}
                """)
        let store = RemoteConfigStore<Empty>(
            configuration: Self.makeConfiguration(
                transport: transport, cacheDirectory: Self.temporaryDirectory()))
        await store.bootstrap()

        #expect(
            store.gateDecision
                == .blocked(minimumVersion: "3.0", updateURL: "https://apps.apple.com/x"))
    }
}

import Foundation
import InMemoryLogging
import KeelServerTesting
import Logging
import Testing

@testable import KeelServer

/// The endpoint that cannot fail, and the one whose *omissions* are the contract: a client on the
/// current build must get no `gate` at all, because presence is what tells it the gate applies.
@Suite("Bootstrap handler")
struct BootstrapHandlerTests {

    static let now = TestClock.default

    /// A handler over a fixed config, with nothing else moving.
    private static func handler(
        _ config: RemoteConfig,
        flagOverride: FeatureFlagsOverride = .none,
        clock: TestClock = TestClock(),
        handler logHandler: InMemoryLogHandler = InMemoryLogHandler()
    ) -> BootstrapHandler {
        BootstrapHandler(
            cache: ConfigCache(
                store: InMemoryConfigStore(config), ttl: 3_600, clock: clock.callable,
                logger: logHandler.logger),
            flagOverride: flagOverride,
            clock: clock.callable,
            logger: logHandler.logger)
    }

    // MARK: - Query parsing

    @Test("The documented query parameters are read and everything else is ignored")
    func parsesQuery() {
        let request = BootstrapHandler.Request(query: [
            "appVersion": "2.1.0", "platform": "macos", "os": "26.1", "locale": "fr_FR",
            "unknown": "x",
        ])
        #expect(request.appVersion == "2.1.0")
        #expect(request.platform == .macOS)
    }

    @Test("An unrecognised platform is nil rather than a rejection")
    func unknownPlatformIsNil() {
        // The opposite of `/v1/ping`, deliberately: refusing to serve config to a client whose
        // platform this build has not heard of would break the newer client, not the older server.
        let request = BootstrapHandler.Request(query: ["platform": "carplay"])
        #expect(request.platform == nil)
        #expect(request.appVersion == nil)
    }

    // MARK: - Features

    @Test("Config flags are served as they are stored")
    func servesFlags() async {
        let response = await Self.handler(
            RemoteConfig(features: ["sleep_timer": true, "anniversary_cover": false])
        ).handle(BootstrapHandler.Request())
        #expect(response.features == ["sleep_timer": true, "anniversary_cover": false])
    }

    @Test("The environment override wins over the config, per flag")
    func overrideWins() async {
        let response = await Self.handler(
            RemoteConfig(features: ["sleep_timer": true, "keep": true]),
            flagOverride: FeatureFlagsOverride(environmentValue: "sleep_timer=false, new=true")
        ).handle(BootstrapHandler.Request())
        #expect(response.features == ["sleep_timer": false, "keep": true, "new": true])
    }

    @Test("A malformed override entry is reported once, at construction")
    func reportsMalformedOverrideOnce() async {
        let logHandler = InMemoryLogHandler()
        let handler = Self.handler(
            .empty,
            flagOverride: FeatureFlagsOverride(environmentValue: "good=true, bad"),
            handler: logHandler)

        _ = await handler.handle(BootstrapHandler.Request())
        _ = await handler.handle(BootstrapHandler.Request())

        // Once, not per request: the variable cannot change for the life of the function, and a
        // warning on every invocation is noise that buries the next real one.
        let warnings = logHandler.entries.filter {
            $0.level == .warning && $0.message.description.contains("FEATURE_FLAGS")
        }
        #expect(warnings.count == 1)
    }

    // MARK: - Telemetry projection

    @Test("The kill switch is projected onto the wire")
    func projectsKillSwitch() async {
        let off = await Self.handler(RemoteConfig(telemetry: .disabled))
            .handle(BootstrapHandler.Request())
        #expect(off.telemetry.isEnabled == false)

        let on = await Self.handler(.empty).handle(BootstrapHandler.Request())
        #expect(on.telemetry.isEnabled)
    }

    @Test("Declared dimension names are advertised, and an empty list is omitted entirely")
    func projectsDimensions() async {
        let declared = await Self.handler(
            RemoteConfig(
                telemetry: TelemetrySettings(dimensions: [
                    DimensionConfig(name: "profiles", buckets: ["1-2", "3-5"]),
                    DimensionConfig(name: "theme", buckets: ["light", "dark"]),
                ]))
        ).handle(BootstrapHandler.Request())
        // Declaration order, which is also the order the dashboard draws them in.
        #expect(declared.telemetry.dimensions == ["profiles", "theme"])

        let none = await Self.handler(.empty).handle(BootstrapHandler.Request())
        // Nil, never `[]`. Absence already says "nothing to state"; `[]` would say "send none",
        // which is a different claim and one no config can currently make.
        #expect(none.telemetry.dimensions == nil)
    }

    @Test("Bucket labels are not advertised")
    func doesNotLeakBuckets() async {
        let response = await Self.handler(
            RemoteConfig(
                telemetry: TelemetrySettings(dimensions: [
                    DimensionConfig(name: "profiles", buckets: ["1-2", "3-5", "6-10"])
                ]))
        ).handle(BootstrapHandler.Request())
        // The client already knows its own buckets — it computed them. Sending the allowlist back
        // would only grow the response and invite a client to derive its buckets from the server.
        #expect(response.telemetry.dimensions == ["profiles"])
    }

    // MARK: - The gate

    /// Thresholds and a link, the shape a real config has.
    static let gateConfig = GateConfig(
        minSupportedVersion: "1.4",
        recommendedVersion: "2.2",
        updateURL: "https://apps.apple.com/app/id1")

    @Test("No gate config, no gate")
    func noGateConfigured() async {
        let response = await Self.handler(.empty)
            .handle(BootstrapHandler.Request(appVersion: "1.0.0"))
        #expect(response.gate == nil)
    }

    @Test("A current build gets no gate section at all")
    func currentBuildIsUngated() async {
        let response = await Self.handler(RemoteConfig(gate: Self.gateConfig))
            .handle(BootstrapHandler.Request(appVersion: "2.2"))
        // Presence is the signal. A client on the current version reasoning about a gate it was
        // sent anyway is exactly the comparison this design moves to the server.
        #expect(response.gate == nil)
    }

    @Test("A build below the minimum is told it is blocked, and where to go")
    func blockedBuild() async throws {
        let response = await Self.handler(RemoteConfig(gate: Self.gateConfig))
            .handle(BootstrapHandler.Request(appVersion: "1.3.9"))
        let gate = try #require(response.gate)
        #expect(gate.minSupportedVersion == "1.4")
        // Below the minimum is also below the recommendation, so both are sent; the client's rule
        // is that blocking wins.
        #expect(gate.recommendedVersion == "2.2")
        #expect(gate.updateURL == "https://apps.apple.com/app/id1")
        #expect(gate.maintenance == nil)
    }

    @Test("A build between the two thresholds is only nudged")
    func softUpdate() async {
        let response = await Self.handler(RemoteConfig(gate: Self.gateConfig))
            .handle(BootstrapHandler.Request(appVersion: "2.1.0"))
        #expect(response.gate?.minSupportedVersion == nil)
        #expect(response.gate?.recommendedVersion == "2.2")
        #expect(response.gate?.updateURL == "https://apps.apple.com/app/id1")
    }

    @Test("Exactly at a threshold is not below it")
    func thresholdIsInclusive() async {
        let response = await Self.handler(
            RemoteConfig(gate: GateConfig(minSupportedVersion: "1.4"))
        ).handle(BootstrapHandler.Request(appVersion: "1.4.0"))
        // `1.4` and `1.4.0` are the same version, and "minimum supported" supports its own value.
        #expect(response.gate == nil)
    }

    @Test("A client that does not say its version is not gated")
    func missingVersionIsUngated() async {
        let response = await Self.handler(RemoteConfig(gate: Self.gateConfig))
            .handle(BootstrapHandler.Request())
        #expect(response.gate == nil)
    }

    @Test("An unparseable client version fails open")
    func unparseableClientVersion() async {
        let response = await Self.handler(RemoteConfig(gate: Self.gateConfig))
            .handle(BootstrapHandler.Request(appVersion: "2.1.0-beta.3"))
        // Blocking every install of a build whose version string the parser has not met is the
        // one outcome no client-side change can undo.
        #expect(response.gate == nil)
    }

    @Test("An unreadable threshold in the config is ignored and warned about")
    func unparseableThreshold() async {
        let logHandler = InMemoryLogHandler()
        let response = await Self.handler(
            RemoteConfig(gate: GateConfig(minSupportedVersion: "v1.4")),
            handler: logHandler
        ).handle(BootstrapHandler.Request(appVersion: "1.0.0"))

        #expect(response.gate == nil)
        // A `minSupportedVersion` that silently does nothing is the failure an operator is least
        // likely to notice on their own.
        #expect(logHandler.hasEntry(atLeast: .warning, containing: "unreadable gate threshold"))
    }

    @Test("The update URL is withheld when there is nothing to update to")
    func noURLWithoutAThreshold() async {
        let response = await Self.handler(
            RemoteConfig(
                gate: GateConfig(
                    updateURL: "https://apps.apple.com/app/id1",
                    maintenance: MaintenanceConfig(message: "Back at 14:00 UTC")))
        ).handle(BootstrapHandler.Request(appVersion: "2.1.0"))

        #expect(response.gate?.maintenance?.message == "Back at 14:00 UTC")
        // A maintenance notice is not an update prompt. A URL beside it would invite a button that
        // sends the user to the App Store to fix an outage they cannot fix.
        #expect(response.gate?.updateURL == nil)
    }

    // MARK: - Maintenance

    @Test("A maintenance notice with no window applies to everyone")
    func maintenanceAppliesToEveryone() async {
        let response = await Self.handler(
            RemoteConfig(gate: GateConfig(maintenance: MaintenanceConfig(message: "Upgrading")))
        ).handle(BootstrapHandler.Request(appVersion: "99.0"))
        #expect(response.gate?.maintenance == Maintenance(message: "Upgrading"))
        #expect(response.gate?.minSupportedVersion == nil)
    }

    @Test("A maintenance window in the past has expired")
    func expiredMaintenance() async {
        let clock = TestClock()
        let response = await Self.handler(
            RemoteConfig(
                gate: GateConfig(
                    maintenance: MaintenanceConfig(
                        message: "Upgrading", until: clock.now.addingTimeInterval(-1)))),
            clock: clock
        ).handle(BootstrapHandler.Request())
        // An operator who set a window should not have to remember to clear it: a forgotten banner
        // blocks an app for no reason, which is worse than having to block it twice.
        #expect(response.gate == nil)
    }

    @Test("A maintenance window still open is in force")
    func activeMaintenance() async {
        let clock = TestClock()
        let until = clock.now.addingTimeInterval(3_600)
        let response = await Self.handler(
            RemoteConfig(
                gate: GateConfig(
                    maintenance: MaintenanceConfig(
                        message: "Upgrading", until: until, allowsDismissal: true))),
            clock: clock
        ).handle(BootstrapHandler.Request())
        #expect(
            response.gate?.maintenance
                == Maintenance(message: "Upgrading", until: until, allowsDismissal: true))
    }

    // MARK: - Per-platform overrides

    static let perPlatformGate = GateConfig(
        minSupportedVersion: "1.4",
        updateURL: "https://apps.apple.com/app/id1",
        platformOverrides: [
            "macos": PlatformGateOverride(
                minSupportedVersion: "2.0", updateURL: "https://example.com/mac")
        ])

    @Test("A platform with overrides gets its own thresholds and link")
    func platformOverride() async {
        let response = await Self.handler(RemoteConfig(gate: Self.perPlatformGate))
            .handle(BootstrapHandler.Request(appVersion: "1.9", platform: .macOS))
        // Sending a Mac user to the iPhone App Store is a dead end, which is the entire reason
        // per-platform overrides exist.
        #expect(response.gate?.minSupportedVersion == "2.0")
        #expect(response.gate?.updateURL == "https://example.com/mac")
    }

    @Test("A platform without overrides gets the base gate")
    func platformWithoutOverride() async {
        let response = await Self.handler(RemoteConfig(gate: Self.perPlatformGate))
            .handle(BootstrapHandler.Request(appVersion: "1.3", platform: .iOS))
        #expect(response.gate?.minSupportedVersion == "1.4")
        #expect(response.gate?.updateURL == "https://apps.apple.com/app/id1")
    }

    @Test("A build that does not identify its platform gets the base gate, not none")
    func unknownPlatformGetsBaseGate() async {
        let response = await Self.handler(RemoteConfig(gate: Self.perPlatformGate))
            .handle(BootstrapHandler.Request(appVersion: "1.3", platform: nil))
        // A blocked build stays blocked when it fails to say what it is.
        #expect(response.gate?.minSupportedVersion == "1.4")
    }

    @Test("A macOS build above its own higher minimum is un-gated even though iOS's is lower")
    func overrideCanRaiseTheBar() async {
        let response = await Self.handler(RemoteConfig(gate: Self.perPlatformGate))
            .handle(BootstrapHandler.Request(appVersion: "2.0", platform: .macOS))
        #expect(response.gate == nil)
    }

    @Test("Maintenance survives platform resolution")
    func maintenanceIsNotOverridable() async {
        var gate = Self.perPlatformGate
        gate.maintenance = MaintenanceConfig(message: "Upgrading")
        let response = await Self.handler(RemoteConfig(gate: gate))
            .handle(BootstrapHandler.Request(appVersion: "2.0", platform: .macOS))
        // An outage is not per-platform. `resolved(for:)` carries it through unchanged, and a
        // client on an otherwise fine build still hears about it.
        #expect(response.gate?.maintenance?.message == "Upgrading")
        #expect(response.gate?.minSupportedVersion == nil)
    }

    // MARK: - Passthrough and resilience

    @Test("URLs and the opaque app payload pass through untouched")
    func passesThroughUrlsAndApp() async {
        let app = JSONValue.object(["streamURL": .string("https://example.com/stream")])
        let response = await Self.handler(
            RemoteConfig(urls: [KeelURL.privacy: "https://example.com/privacy"], app: app)
        ).handle(BootstrapHandler.Request())
        #expect(response.urls == ["privacy": "https://example.com/privacy"])
        #expect(response.app == app)
    }

    @Test("The response is stamped and versioned")
    func stampsTheResponse() async {
        let clock = TestClock()
        let response = await Self.handler(.empty, clock: clock)
            .handle(BootstrapHandler.Request())
        #expect(response.generatedAt == clock.now)
        #expect(response.schemaVersion == Keel.schemaVersion)
    }

    @Test("An unreadable table still produces a usable response")
    func survivesAnUnreadableTable() async {
        let store = InMemoryConfigStore(nil)
        store.failLoads()
        let logHandler = InMemoryLogHandler()
        let handler = BootstrapHandler(
            cache: ConfigCache(
                store: store,
                fallback: RemoteConfig(features: ["compiled_in": true]),
                ttl: 60,
                clock: { Self.now },
                logger: logHandler.logger),
            clock: { Self.now },
            logger: logHandler.logger)

        // Not throwing is the assertion. A 500 here means every launching app falls back to its
        // compiled-in defaults at once — including the ones that never shipped any.
        let response = await handler.handle(BootstrapHandler.Request(appVersion: "1.0.0"))
        #expect(response.features == ["compiled_in": true])
        #expect(response.telemetry.isEnabled)
        #expect(response.gate == nil)
    }
}

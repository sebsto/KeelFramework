public import Foundation
public import KeelCore
public import Observation

/// The app's window onto its remote configuration: flags, gate, URLs, and the app's own
/// payload, observable by SwiftUI.
///
/// Three tiers, best first: tonight's network response ▸ the disk cache from a previous
/// launch ▸ nothing, which reads as compiled-in defaults everywhere
/// (`docs/ARCHITECTURE.md` §6). The tiers exist because the alternative failure modes are
/// both wrong: waiting on the network holds the launch hostage to a 3-second budget, and
/// network-only means an offline launch loses the kill switch state it knew yesterday.
///
/// Call `bootstrap()` from the root view's `.task`. It publishes the cache immediately —
/// the UI renders with last-known-good before the network answers — then refreshes.
@Observable
@MainActor
public final class RemoteConfigStore<App: Decodable & Sendable> {
    /// The best response available right now, or nil before the first tier resolves.
    /// Nil reads as "no opinion": flags at defaults, no gate, no payload.
    public private(set) var response: BootstrapResponse<App>?

    /// Where `response` came from, for a debug screen.
    public enum Source: Sendable, Equatable {
        case none, diskCache, network
    }

    public private(set) var source: Source = .none

    private let configuration: KeelConfiguration
    private let client: BackendClient

    public init(configuration: KeelConfiguration) {
        self.configuration = configuration
        self.client = configuration.client
    }

    // MARK: - Derived views

    /// The resolved flag set: compiled-in defaults, server overrides on top.
    public var flags: FeatureFlagSet {
        FeatureFlagSet(defaults: configuration.flagDefaults)
            .applying(response?.features ?? [:])
    }

    /// What to do about the version gate. `.proceed` until a response exists — the gate
    /// can only act on what the server actually said.
    public var gateDecision: VersionGateDecision {
        VersionGateDecision.evaluate(response?.gate)
    }

    /// The server's telemetry section, for `TelemetryService`. Fails open by default.
    public var telemetry: TelemetryConfig {
        response?.telemetry ?? .default
    }

    /// The app's own payload, or nil when no tier has one.
    public var app: App? {
        response?.app
    }

    /// A well-known URL by `KeelURL` key, absent when the config does not state it —
    /// the caller's compiled-in link is the fallback, as everywhere else.
    public func url(_ key: String) -> URL? {
        (response?.urls[key]).flatMap(URL.init(string:))
    }

    // MARK: - Lifecycle

    /// Load the cache, publish it, then refresh from the network. The intended launch
    /// call: the UI observes `response` and updates as each tier lands.
    public func bootstrap() async {
        loadFromDisk()
        await refresh()
    }

    /// Fetch from the network and, on success, publish and persist. On failure the
    /// current tier stays — a stale config beats no config, and beats an error even more.
    public func refresh() async {
        do {
            let (response, body) = try await client.bootstrapWithBody(
                appVersion: configuration.appVersion,
                platform: configuration.platform,
                osVersion: configuration.osVersion,
                as: App.self)
            self.response = response
            self.source = .network
            persist(body)
        } catch {
            configuration.log.debug(
                "Bootstrap refresh failed (\(error)); serving \(source) tier")
        }
    }

    // MARK: - Disk cache

    private var cacheFile: URL {
        configuration.cacheDirectory.appendingPathComponent("bootstrap.json")
    }

    private func loadFromDisk() {
        guard source == .none else { return }
        guard let data = try? Data(contentsOf: cacheFile) else { return }
        // The verbatim bytes of a previous response. A decode failure — an app-payload
        // type change, a corrupted file — quietly falls through to defaults; yesterday's
        // cache is a convenience, never a requirement.
        guard let cached = try? WireJSON.decoder().decode(BootstrapResponse<App>.self, from: data)
        else {
            configuration.log.warning("Discarding an unreadable bootstrap cache")
            try? FileManager.default.removeItem(at: cacheFile)
            return
        }
        response = cached
        source = .diskCache
    }

    private func persist(_ body: Data) {
        do {
            try FileManager.default.createDirectory(
                at: configuration.cacheDirectory, withIntermediateDirectories: true)
            try body.write(to: cacheFile, options: .atomic)
        } catch {
            // A launch without a cache next time, nothing worse.
            configuration.log.debug("Could not persist the bootstrap cache: \(error)")
        }
    }
}

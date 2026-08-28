import KeelClient
import KeelCore
import SwiftUI

/// The app's flag vocabulary. One case per flag, each with its compiled-in default —
/// `defaultValue` is a required member, so a new flag without a decision does not compile.
enum AppFlag: String, KeelFlag {
    case confetti = "confetti"
    case newOnboarding = "new_onboarding"

    var defaultValue: Bool {
        switch self {
        case .confetti: false
        case .newOnboarding: false
        }
    }
}

/// The app's own remote payload — whatever launch-time configuration it needs beyond
/// Keel's. Delete the property and use `RemoteConfigStore<Empty>` if you have none.
/// The conformance is nonisolated so it satisfies `RemoteConfigStore`'s `Sendable`
/// constraint under strict concurrency.
struct AppPayload: Sendable, Equatable {
    var welcomeMessage: String?
}

extension AppPayload: Decodable {
    nonisolated init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        welcomeMessage = try container.decodeIfPresent(String.self, forKey: .welcomeMessage)
    }

    private enum CodingKeys: String, CodingKey {
        case welcomeMessage
    }
}

@main
struct SampleApp: App {
    /// One configuration, built once. `baseURL` is the only thing you must change —
    /// and it must be a name you own before the first public release
    /// (docs/adr/0007-stable-base-url.md).
    private static let keel = KeelConfiguration(
        baseURL: URL(string: "https://api.example.com")!,
        flagDefaults: AppFlag.flagDefaults)

    @State private var config = RemoteConfigStore<AppPayload>(configuration: Self.keel)
    @State private var flags = FeatureFlags<AppFlag>()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(config)
                .environment(flags)
                // Root-level and outside navigation: a blocked build must not be
                // navigable around.
                .keelVersionGate(config.gateDecision)
                .task {
                    // Tier by tier: the cache renders first, the network updates it.
                    await config.bootstrap()
                    flags.update(from: config.response?.features ?? [:])

                    // The ping reads the *cached* config's telemetry section, so it has
                    // no ordering dependency on the fetch above succeeding.
                    await TelemetryService(configuration: Self.keel).run(
                        licenseState: .free,  // or entitlements.licenseState
                        telemetry: config.telemetry)
                }
        }
    }
}

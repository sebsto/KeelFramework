import KeelClient
import KeelCore
import SwiftUI

struct ContentView: View {
    @Environment(RemoteConfigStore<AppPayload>.self) private var config
    @Environment(FeatureFlags<AppFlag>.self) private var flags

    var body: some View {
        NavigationStack {
            List {
                Section("Remote config") {
                    LabeledContent("Source", value: String(describing: config.source))
                    LabeledContent(
                        "Welcome",
                        value: config.app?.welcomeMessage ?? "(compiled-in default)")
                    if let privacy = config.url(KeelURL.privacy) {
                        Link("Privacy policy", destination: privacy)
                    }
                }

                Section("Flags") {
                    // Flag reads are typed: `flags[.confetti]` cannot typo a name.
                    LabeledContent("confetti", value: flags[.confetti] ? "on" : "off")
                    LabeledContent(
                        "new_onboarding", value: flags[.newOnboarding] ? "on" : "off")
                }

                Section {
                    NavigationLink("Settings") { SettingsView() }
                }
            }
            .navigationTitle("Sample")
        }
    }
}

struct SettingsView: View {
    var body: some View {
        Form {
            Section {
                TelemetryToggle()
            } footer: {
                TelemetryToggle.footer
            }
        }
        .navigationTitle("Settings")
    }
}

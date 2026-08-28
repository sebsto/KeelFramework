public import SwiftUI

/// The settings row for the telemetry opt-out — drop it into a settings `Form`.
///
/// It reads and writes `TelemetryService.Key.isEnabled` through the same tri-state rule
/// the service uses (absent means enabled), so the row and the behavior cannot disagree.
/// The footer states what is actually collected; an app whose settings screen writes its
/// own copy should keep it as blunt as this one.
public struct TelemetryToggle: View {
    private let store: any KeyValueStore

    @State private var isEnabled: Bool

    public init(store: any KeyValueStore = UserDefaults.standard) {
        self.store = store
        self._isEnabled = State(
            initialValue: store.bool(forKey: TelemetryService.Key.isEnabled) ?? true)
    }

    public var body: some View {
        Toggle(isOn: binding) {
            Text("Share Anonymous Usage", bundle: .module)
        }
    }

    /// The explanatory footer, exposed separately so the app places it per its own
    /// settings style: `Section(footer: TelemetryToggle.footer) { TelemetryToggle() }`.
    public static var footer: some View {
        Text(
            "Counts launches and app version — never an identifier, and never anything you do in the app. Everything collected is public.",
            bundle: .module)
    }

    private var binding: Binding<Bool> {
        Binding(
            get: { isEnabled },
            set: { newValue in
                isEnabled = newValue
                store.set(newValue, forKey: TelemetryService.Key.isEnabled)
            })
    }
}

public import KeelCore
public import SwiftUI

/// Present the version gate over this view: a blocking screen for `.blocked` and hard
/// `.maintenance`, a dismissible banner for `.softUpdate`, nothing for `.proceed`.
///
/// ```swift
/// ContentView()
///     .keelVersionGate(store.gateDecision)
/// ```
///
/// Apply it at the root, outside navigation — a blocked build must not be navigable
/// around. The decision is a plain value, so an app with its own screens switches on
/// `VersionGateDecision` instead and never touches these views.
extension View {
    public func keelVersionGate(_ decision: VersionGateDecision) -> some View {
        modifier(VersionGateModifier(decision: decision))
    }
}

struct VersionGateModifier: ViewModifier {
    let decision: VersionGateDecision

    /// Per-launch, deliberately not persisted: a dismissed nudge or dismissible notice
    /// returns next launch, which is the agreed nagging cadence of a *soft* update.
    @State private var isDismissed = false

    init(decision: VersionGateDecision) {
        self.decision = decision
    }

    func body(content: Content) -> some View {
        switch decision {
        case .proceed:
            content
        case .softUpdate(let version, let updateURL):
            content.safeAreaInset(edge: .top) {
                if !isDismissed {
                    SoftUpdateBanner(
                        version: version,
                        updateURL: updateURL.flatMap(URL.init(string:)),
                        onDismiss: { isDismissed = true })
                }
            }
        case .blocked(let minimum, let updateURL):
            UpdateRequiredView(
                minimumVersion: minimum, updateURL: updateURL.flatMap(URL.init(string:)))
        case .maintenance(let maintenance):
            if maintenance.allowsDismissal && isDismissed {
                content
            } else {
                MaintenanceView(
                    maintenance: maintenance,
                    onDismiss: maintenance.allowsDismissal ? { isDismissed = true } : nil)
            }
        }
    }
}

/// The blocking update screen. Full-screen and dead-ended on purpose: `minSupportedVersion`
/// is for builds that are actively harmful, and "later" is not one of the options.
public struct UpdateRequiredView: View {
    public let minimumVersion: String
    public let updateURL: URL?

    @Environment(\.openURL) private var openURL

    public init(minimumVersion: String, updateURL: URL?) {
        self.minimumVersion = minimumVersion
        self.updateURL = updateURL
    }

    public var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Update Required", bundle: .module)
                .font(.title2.bold())
            Text(
                "This version is no longer supported. Please update to \(minimumVersion) or later to continue.",
                bundle: .module
            )
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            if let updateURL {
                Button {
                    openURL(updateURL)
                } label: {
                    Text("Update Now", bundle: .module)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background()
    }
}

/// The dismissible nudge for `recommendedVersion`.
public struct SoftUpdateBanner: View {
    public let version: String
    public let updateURL: URL?
    public let onDismiss: () -> Void

    @Environment(\.openURL) private var openURL

    public init(version: String, updateURL: URL?, onDismiss: @escaping () -> Void) {
        self.version = version
        self.updateURL = updateURL
        self.onDismiss = onDismiss
    }

    public var body: some View {
        HStack(spacing: 12) {
            Text("Version \(version) is available.", bundle: .module)
                .font(.callout)
            Spacer()
            if let updateURL {
                Button {
                    openURL(updateURL)
                } label: {
                    Text("Update", bundle: .module)
                }
                .font(.callout.bold())
            }
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.bold())
            }
            .accessibilityLabel(Text("Dismiss", bundle: .module))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.thinMaterial)
    }
}

/// The outage screen. The message is server-supplied and shown as *text* — never markup,
/// never a link — because it crosses a trust boundary on the way here.
public struct MaintenanceView: View {
    public let maintenance: Maintenance
    public let onDismiss: (() -> Void)?

    public init(maintenance: Maintenance, onDismiss: (() -> Void)? = nil) {
        self.maintenance = maintenance
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Temporarily Unavailable", bundle: .module)
                .font(.title2.bold())
            Text(verbatim: maintenance.message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if let until = maintenance.until {
                Text("Expected back \(until, format: .dateTime).", bundle: .module)
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            if let onDismiss {
                Button {
                    onDismiss()
                } label: {
                    Text("Continue Anyway", bundle: .module)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background()
    }
}

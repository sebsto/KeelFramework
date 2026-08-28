public import Foundation
public import KeelCore

/// Everything Keel needs from the app, built once in `@main` and handed to the stores.
///
/// Only `baseURL` is required. The platform facts are detected; the seams (`transport`,
/// `defaults`, `now`) exist for tests and have production defaults.
public struct KeelConfiguration: Sendable {
    /// The backend's base URL — the stable name, not an `execute-api` hostname
    /// (`docs/adr/0007-stable-base-url.md`).
    public var baseURL: URL

    /// Sent as `Authorization` on every request. `.none` for public backends.
    public var authorization: KeelAuthorization

    /// Compiled-in flag defaults, keyed by wire name. The complete list of flags this
    /// build knows; `FeatureFlags` asserts its `Flag` enum matches.
    public var flagDefaults: [String: Bool]

    /// Where the bootstrap disk cache lives. Defaults to `Application Support/Keel/`.
    public var cacheDirectory: URL

    /// The running build's marketing version, from the bundle. Sent in the bootstrap
    /// query — it is what the version gate reasons about — and in every ping.
    public var appVersion: String

    public var osVersion: String
    public var platform: Platform

    /// True while the app is in a demo/review mode that promises no network calls.
    /// Checked before every ping; App Review expects offline operation in demo.
    public var isDemoMode: @Sendable () -> Bool

    public var transport: any HTTPTransport
    public var defaults: any KeyValueStore
    public var log: any KeelLog
    public var now: @Sendable () -> Date

    /// `@MainActor` because platform detection reads `UIDevice` on iOS. Build it in your
    /// `@main` type — where it belongs anyway — or pass `platform:` explicitly from
    /// elsewhere.
    @MainActor
    public init(
        baseURL: URL,
        authorization: KeelAuthorization = .none,
        flagDefaults: [String: Bool] = [:],
        cacheDirectory: URL? = nil,
        appVersion: String? = nil,
        osVersion: String? = nil,
        platform: Platform? = nil,
        isDemoMode: @escaping @Sendable () -> Bool = { false },
        transport: any HTTPTransport = URLSessionTransport(),
        defaults: any KeyValueStore = UserDefaults.standard,
        log: any KeelLog = OSKeelLog(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.baseURL = baseURL
        self.authorization = authorization
        self.flagDefaults = flagDefaults
        self.cacheDirectory =
            cacheDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Keel", isDirectory: true)
        self.appVersion = appVersion ?? Self.bundleVersion
        self.osVersion = osVersion ?? Self.currentOSVersion
        self.platform = platform ?? Self.currentPlatform
        self.isDemoMode = isDemoMode
        self.transport = transport
        self.defaults = defaults
        self.log = log
        self.now = now
    }

    /// The client the stores share, built from the pieces above.
    public var client: BackendClient {
        BackendClient(baseURL: baseURL, authorization: authorization, transport: transport)
    }

    // MARK: - Detection

    /// `CFBundleShortVersionString`, the marketing version — the same string the operator
    /// types into the gate config. `0.0` when absent (unit test hosts), which the server's
    /// parser reads as a valid, very old version.
    static var bundleVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.0"
    }

    static var currentOSVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        // Two components unless the patch matters: "26.1", not "26.1.0" — these become
        // sort keys in a distribution, and "26.1" and "26.1.0" would chart as two bars.
        return version.patchVersion == 0
            ? "\(version.majorVersion).\(version.minorVersion)"
            : "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    @MainActor
    static var currentPlatform: Platform {
        #if os(macOS)
        return .macOS
        #elseif os(tvOS)
        return .tvOS
        #elseif os(watchOS)
        return .watchOS
        #elseif os(visionOS)
        return .visionOS
        #elseif os(iOS)
        // iPadOS is iOS at compile time; the idiom is a runtime fact.
        return UIDevice.current.userInterfaceIdiom == .pad ? .iPadOS : .iOS
        #else
        return .linux
        #endif
    }
}

#if os(iOS)
import UIKit
#endif

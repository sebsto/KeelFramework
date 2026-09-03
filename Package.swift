// swift-tools-version: 6.2
import PackageDescription

/// Strict settings applied to every target. `KeelCore` additionally has to stay
/// source-compatible with Skip's Kotlin transpiler (see Sources/KeelCore/README.md),
/// which is a discipline enforced by review and by the Android build of a consuming
/// app — not by anything in this manifest. Nothing here depends on Skip, so an
/// Apple-only app pays nothing for it.
let strictSettings: [SwiftSetting] = [
    .treatAllWarnings(as: .error),
    // https://github.com/swiftlang/swift-evolution/blob/main/proposals/0335-existential-any.md
    .enableUpcomingFeature("ExistentialAny"),
    // https://github.com/swiftlang/swift-evolution/blob/main/proposals/0444-member-import-visibility.md
    .enableUpcomingFeature("MemberImportVisibility"),
    // https://github.com/swiftlang/swift-evolution/blob/main/proposals/0409-access-level-on-imports.md
    .enableUpcomingFeature("InternalImportsByDefault"),
    // https://docs.swift.org/compiler/documentation/diagnostics/nonisolated-nonsending-by-default/
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let package = Package(
    name: "Keel",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .tvOS(.v17),
        .watchOS(.v10),
        .visionOS(.v1),
    ],
    products: [
        // The Skip-safe lower layer: wire types, transport, and the pure decision
        // logic. Depend on this alone from a cross-platform (Skip) module.
        .library(name: "KeelCore", targets: ["KeelCore"]),
        // The Apple-platform layer: @Observable stores, SwiftUI, StoreKit.
        .library(name: "KeelClient", targets: ["KeelClient"]),
        // Fakes and helpers for an app's own test target.
        .library(name: "KeelClientTesting", targets: ["KeelClientTesting"]),
    ],
    // Deliberately no dependencies. A client app adopting Keel must not have to
    // resolve, audit, or ship a transitive dependency graph for what is a handful
    // of Codable types and one URLSession call.
    dependencies: [],
    targets: [
        .target(
            name: "KeelCore",
            // The rules this target has to follow to stay Skip-transpilable.
            exclude: ["README.md"],
            swiftSettings: strictSettings
        ),
        .target(
            name: "KeelClient",
            dependencies: ["KeelCore"],
            resources: [.copy("Resources/PrivacyInfo.xcprivacy")],
            swiftSettings: strictSettings
        ),
        .target(
            name: "KeelClientTesting",
            dependencies: ["KeelCore", "KeelClient"],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "KeelCoreTests",
            dependencies: ["KeelCore"],
            // Fixtures are wired via #filePath walking in Tests/KeelCoreTests/Fixture.swift —
            // the loader walks up to Fixtures/ at the repo root, so no resource bundle copy
            // is needed. Both KeelCoreTests and KeelServerTests share the same files this way,
            // which is the point: a renamed field breaks both suites at once.
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "KeelClientTests",
            dependencies: ["KeelClient", "KeelClientTesting"],
            swiftSettings: strictSettings
        ),
    ]
)

// swift-tools-version: 6.2
import PackageDescription

/// Strict settings applied to every hand-written target. `KeelCore` additionally has to
/// stay source-compatible with Skip's Kotlin transpiler (see Sources/KeelCore/README.md),
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

/// The code-generated Soto service clients do not satisfy the strict flags above
/// and are not ours to fix, so they build with the minimum.
let generatedSettings: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault")
]

/// Whether to offer the client half of the framework at all.
///
/// `KeelClient` is SwiftUI, StoreKit and Observation, so it cannot compile on Linux —
/// and the two places SwiftPM reads this manifest on Linux are exactly the two that must
/// not need it: the CI leg that gates the Lambda, and the container that cross-compiles
/// the Lambda for `PROVIDED_AL2023`. Omitting the client targets there keeps
/// `swift build` and `swift test` working as plain, unqualified commands on both hosts,
/// and makes the Lambda build smaller as a side effect.
///
/// This tests the machine running SwiftPM, not the platform being built for: on macOS the
/// whole package is present, so an iOS or macOS app resolving Keel always sees the client
/// libraries.
#if os(Linux)
let includeClientTargets = false
#else
let includeClientTargets = true
#endif

/// Products for the app: no dependencies of their own, so an app that imports only these
/// links nothing from the server's dependency graph.
let clientProducts: [Product] = [
    // The Skip-safe lower layer: wire types, transport, and the pure decision
    // logic. Depend on this alone from a cross-platform (Skip) module.
    .library(name: "KeelCore", targets: ["KeelCore"]),
    // The Apple-platform layer: @Observable stores, SwiftUI, StoreKit.
    .library(name: "KeelClient", targets: ["KeelClient"]),
    // The reference AWS SigV4 signing transport, for apps deployed behind
    // `KeelAuth.iam()`. A production library (Apple/CryptoKit-gated) so a shipping
    // target can depend on it without pulling in the test-support module.
    .library(name: "KeelClientSigning", targets: ["KeelClientSigning"]),
    // Fakes and helpers for an app's own test target.
    .library(name: "KeelClientTesting", targets: ["KeelClientTesting"]),
]

let clientTargets: [Target] = [
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
        name: "KeelClientSigning",
        dependencies: ["KeelCore"],
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
        dependencies: ["KeelClient", "KeelClientSigning", "KeelClientTesting"],
        swiftSettings: strictSettings
    ),
]

let package = Package(
    name: "Keel",
    platforms: [
        .iOS(.v17),
        // swift-aws-lambda-runtime 3.x requires macOS 15 for its local test server, and
        // SwiftPM applies a platform floor package-wide. A macOS client app therefore
        // needs macOS 15 as well, even though it links none of the server libraries.
        .macOS(.v15),
        .tvOS(.v17),
        .watchOS(.v10),
        .visionOS(.v1),
    ],
    products: (includeClientTargets ? clientProducts : []) + [
        // MARK: Server — for the app's Lambda

        // Handlers, schema, and store protocols. Depend on this from your own
        // Lambda when your app adds routes of its own.
        .library(name: "KeelServer", targets: ["KeelServer"]),
        // Fakes for testing handlers without AWS.
        .library(name: "KeelServerTesting", targets: ["KeelServerTesting"]),
        // Soto-backed CounterStore/ConfigStore implementations.
        .library(name: "KeelServerDynamoDB", targets: ["KeelServerDynamoDB"]),
        // The lambda-kit route table for the framework endpoints. Depend on this from
        // your own Lambda and call `builder.mount(keel:)` to add your routes beside them.
        .library(name: "KeelRouter", targets: ["KeelRouter"]),
        // App Store JWS + notification verification — optional; apps without server-side
        // App Store verification never import it or its crypto dependencies.
        .library(name: "KeelAppStore", targets: ["KeelAppStore"]),
        // Fixture factory for building verified-payload values in tests.
        .library(name: "KeelAppStoreTesting", targets: ["KeelAppStoreTesting"]),
        .library(name: "KeelAppStoreRouter", targets: ["KeelAppStoreRouter"]),

        // MARK: Executables

        // Ready-made executable: the framework routes, driven by configuration.
        .executable(name: "KeelLambda", targets: ["KeelLambda"]),
        // API Gateway Lambda authorizer for the `sharedSecret` auth mode.
        .executable(name: "KeelAuthorizerLambda", targets: ["KeelAuthorizerLambda"]),
        // Admin CLI: read/write the config item, dump the counters.
        .executable(name: "keel", targets: ["keel-cli"]),
    ],
    // These are the server's dependencies. A client target links none of them —
    // `KeelCore` and `KeelClient` have no dependencies at all — but SwiftPM resolves a
    // package's whole dependency list, so an app that imports only the client libraries
    // still checks these out. That is the cost of shipping both halves from one
    // manifest, which is what lets an app depend on Keel with a single package URL.
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.13.0"),
        .package(url: "https://github.com/awslabs/swift-aws-lambda-runtime", from: "3.0.0-rc1"),
        .package(url: "https://github.com/awslabs/swift-aws-lambda-events.git", from: "1.5.0"),
        // Fork of SongShift/lambda-kit widening the swift-aws-lambda-runtime pin to
        // 3.x (upstream pins 2.6.x). Only the `Routing` library is used, and it does
        // not itself depend on the runtime. Pinned by exact revision so a force-push
        // cannot change what we build; the pin is temporary — see
        // docs/adr/0002-lambda-kit-fork.md for the exit criteria.
        .package(url: "https://github.com/sebsto/lambda-kit.git", revision: "5b2b025635a872345e7711177fe5b56a5ce81fad"),
        // Soto core only: the DynamoDB client is code-generated into
        // server/Sources/Soto/DynamoDB by scripts/generate-soto.sh. aws-sdk-swift is
        // deliberately not used — its aws-crt TLS layer crashes at Lambda cold start
        // (docs/adr/0006-codegen-soto.md).
        .package(url: "https://github.com/soto-project/soto-core.git", from: "7.13.0"),
        .package(url: "https://github.com/apple/swift-configuration.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.0"),
        // KeelAppStore only: StoreKit-2 JWS verification is X.509 chain validation plus an
        // ES256 signature, and these are the pieces worth depending on for that.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.10.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.10.0"),
        .package(url: "https://github.com/apple/swift-asn1.git", from: "1.3.0"),
    ],
    targets: (includeClientTargets ? clientTargets : []) + [
        // MARK: - Server targets (server/Sources/)

        .target(
            name: "KeelServer",
            dependencies: [
                .product(name: "Logging", package: "swift-log")
            ],
            path: "server/Sources/KeelServer",
            swiftSettings: strictSettings
        ),
        .target(
            name: "KeelServerTesting",
            dependencies: [
                "KeelServer",
                .product(name: "Logging", package: "swift-log"),
                // swift-log's own capturing handler. Keel does not ship one of its own: several
                // of the framework's promises ("the operator is told") are only observable in a
                // log line, and asserting them needs a handler, not a new one.
                .product(name: "InMemoryLogging", package: "swift-log"),
            ],
            path: "server/Sources/KeelServerTesting",
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "KeelServerTests",
            dependencies: [
                "KeelServer",
                "KeelRouter",
                "KeelServerTesting",
                .product(name: "AWSLambdaEvents", package: "swift-aws-lambda-events"),
                .product(name: "Routing", package: "lambda-kit"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "InMemoryLogging", package: "swift-log"),
            ],
            path: "server/Tests/KeelServerTests",
            swiftSettings: strictSettings
        ),

        // MARK: - AWS

        // Code-generated by scripts/generate-soto.sh — do not edit by hand. Builds with
        // relaxed settings because it is not ours to fix.
        .target(
            name: "SotoDynamoDB",
            dependencies: [.product(name: "SotoCore", package: "soto-core")],
            path: "server/Sources/Soto/DynamoDB",
            swiftSettings: generatedSettings
        ),
        .target(
            name: "SotoSSM",
            dependencies: [.product(name: "SotoCore", package: "soto-core")],
            path: "server/Sources/Soto/SSM",
            swiftSettings: generatedSettings
        ),
        .target(
            name: "KeelServerDynamoDB",
            dependencies: [
                "KeelServer",
                "SotoDynamoDB",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "server/Sources/KeelServerDynamoDB",
            swiftSettings: strictSettings
        ),
        // The one target that imports `Routing`, apart from the executable that uses it.
        // Replacing the router (docs/adr/0002-lambda-kit-fork.md, exit 3) touches this
        // target and nothing else.
        .target(
            name: "KeelRouter",
            dependencies: [
                "KeelServer",
                .product(name: "Routing", package: "lambda-kit"),
                .product(name: "AWSLambdaEvents", package: "swift-aws-lambda-events"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "server/Sources/KeelRouter",
            swiftSettings: strictSettings
        ),
        .executableTarget(
            name: "KeelLambda",
            dependencies: [
                "KeelServer",
                "KeelServerDynamoDB",
                "KeelRouter",
                "KeelAppStore",
                "KeelAppStoreRouter",
                .product(name: "AWSLambdaRuntime", package: "swift-aws-lambda-runtime"),
                .product(name: "AWSLambdaEvents", package: "swift-aws-lambda-events"),
                .product(name: "Routing", package: "lambda-kit"),
                .product(name: "Configuration", package: "swift-configuration"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "server/Sources/KeelLambda",
            swiftSettings: strictSettings
        ),
        .executableTarget(
            name: "KeelAuthorizerLambda",
            dependencies: [
                "SotoSSM",
                .product(name: "AWSLambdaRuntime", package: "swift-aws-lambda-runtime"),
                .product(name: "AWSLambdaEvents", package: "swift-aws-lambda-events"),
                .product(name: "Configuration", package: "swift-configuration"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "server/Sources/KeelAuthorizerLambda",
            swiftSettings: strictSettings
        ),
        .target(
            name: "KeelAppStore",
            dependencies: [
                "KeelServer",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "server/Sources/KeelAppStore",
            swiftSettings: strictSettings
        ),
        // Fixture factory: builds verified-payload values (`NotificationPayload`,
        // `SignedTransactionInfo`) for tests. Reaches their `package`-scoped inits because it
        // is the same package — so tests stay easy while an adopting app cannot fabricate a
        // "verified" payload.
        .target(
            name: "KeelAppStoreTesting",
            dependencies: [
                "KeelAppStore"
            ],
            path: "server/Sources/KeelAppStoreTesting",
            swiftSettings: strictSettings
        ),
        .target(
            name: "KeelAppStoreRouter",
            dependencies: [
                "KeelAppStore",
                "KeelServer",
                .product(name: "Routing", package: "lambda-kit"),
                .product(name: "AWSLambdaEvents", package: "swift-aws-lambda-events"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "server/Sources/KeelAppStoreRouter",
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "KeelAppStoreTests",
            dependencies: [
                "KeelAppStore",
                "KeelAppStoreTesting",
                "KeelAppStoreRouter",
                "KeelServer",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
                .product(name: "AWSLambdaEvents", package: "swift-aws-lambda-events"),
                .product(name: "Routing", package: "lambda-kit"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "server/Tests/KeelAppStoreTests",
            swiftSettings: strictSettings
        ),
        .executableTarget(
            name: "keel-cli",
            dependencies: [
                "KeelServer",
                "KeelServerDynamoDB",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "server/Sources/keel-cli",
            swiftSettings: strictSettings
        ),
    ]
)

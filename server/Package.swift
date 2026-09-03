// swift-tools-version: 6.2
import PackageDescription

let strictSettings: [SwiftSetting] = [
    .treatAllWarnings(as: .error),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

/// The code-generated Soto service clients do not satisfy the strict flags above
/// and are not ours to fix, so they build with the minimum.
let generatedSettings: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault")
]

let package = Package(
    name: "KeelServer",
    platforms: [
        // swift-aws-lambda-runtime 3.x requires macOS 15 for the local test server.
        .macOS(.v15)
    ],
    products: [
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
        // Ready-made executable: the framework routes, driven by configuration.
        .executable(name: "KeelLambda", targets: ["KeelLambda"]),
        // API Gateway Lambda authorizer for the `sharedSecret` auth mode.
        .executable(name: "KeelAuthorizerLambda", targets: ["KeelAuthorizerLambda"]),
        // Admin CLI: read/write the config item, dump the counters.
        .executable(name: "keel", targets: ["keel-cli"]),
        // App Store purchases and entitlements — optional; apps without server-side
        // IAP never link it or its crypto dependencies.
        .library(name: "KeelIAP", targets: ["KeelIAP"]),
        .library(name: "KeelIAPDynamoDB", targets: ["KeelIAPDynamoDB"]),
        .library(name: "KeelIAPRouter", targets: ["KeelIAPRouter"]),
    ],
    // Each dependency is commented in until the phase that first needs it, so
    // `swift build` never resolves something no target imports. All of them are
    // verified to resolve together; see docs/adr/0002-lambda-kit-fork.md.
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.13.0"),
        .package(url: "https://github.com/awslabs/swift-aws-lambda-runtime", from: "3.0.0-rc1"),
        .package(url: "https://github.com/awslabs/swift-aws-lambda-events.git", from: "1.5.0"),
        // Fork of SongShift/lambda-kit widening the swift-aws-lambda-runtime pin to
        // 3.x (upstream pins 2.6.x). Only the `Routing` library is used, and it does
        // not itself depend on the runtime. Pinned by exact revision (the current HEAD
        // of the fork's support-runtime-3 branch) so a force-push cannot change what we
        // build; the pin is temporary — see docs/adr/0002-lambda-kit-fork.md for the
        // exit criteria and docs/INTEGRATION.md for the app-side compatibility note.
        .package(url: "https://github.com/sebsto/lambda-kit.git", revision: "5b2b025635a872345e7711177fe5b56a5ce81fad"),
        // Soto core only: the DynamoDB client is code-generated into
        // Sources/Soto/DynamoDB by scripts/generate-soto.sh. aws-sdk-swift is
        // deliberately not used — its aws-crt TLS layer crashes at Lambda cold start
        // (docs/adr/0006-codegen-soto.md).
        .package(url: "https://github.com/soto-project/soto-core.git", from: "7.13.0"),
        .package(url: "https://github.com/apple/swift-configuration.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.0"),
        // KeelIAP only: StoreKit-2 JWS verification is X.509 chain validation plus an
        // ES256 signature, and these are the pieces worth depending on for that.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.10.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.10.0"),
        .package(url: "https://github.com/apple/swift-asn1.git", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "KeelServer",
            dependencies: [
                .product(name: "Logging", package: "swift-log")
            ],
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
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "KeelServerTests",
            dependencies: [
                "KeelServer",
                "KeelRouter",
                "KeelServerTesting",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "InMemoryLogging", package: "swift-log"),
            ],
            // Phase 1 adds the golden-JSON fixtures the client suite reads too.
            // resources: [.copy("Fixtures")],
            swiftSettings: strictSettings
        ),

        // MARK: - AWS

        // Code-generated by scripts/generate-soto.sh — do not edit by hand. Builds with
        // relaxed settings because it is not ours to fix.
        .target(
            name: "SotoDynamoDB",
            dependencies: [.product(name: "SotoCore", package: "soto-core")],
            path: "Sources/Soto/DynamoDB",
            swiftSettings: generatedSettings
        ),
        .target(
            name: "SotoSSM",
            dependencies: [.product(name: "SotoCore", package: "soto-core")],
            path: "Sources/Soto/SSM",
            swiftSettings: generatedSettings
        ),
        .target(
            name: "KeelServerDynamoDB",
            dependencies: [
                "KeelServer",
                "SotoDynamoDB",
                .product(name: "Logging", package: "swift-log"),
            ],
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
            swiftSettings: strictSettings
        ),
        .executableTarget(
            name: "KeelLambda",
            dependencies: [
                "KeelServer",
                "KeelServerDynamoDB",
                "KeelRouter",
                "KeelIAP",
                "KeelIAPDynamoDB",
                "KeelIAPRouter",
                .product(name: "AWSLambdaRuntime", package: "swift-aws-lambda-runtime"),
                .product(name: "AWSLambdaEvents", package: "swift-aws-lambda-events"),
                .product(name: "Routing", package: "lambda-kit"),
                .product(name: "Configuration", package: "swift-configuration"),
                .product(name: "Logging", package: "swift-log"),
            ],
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
            swiftSettings: strictSettings
        ),
        .target(
            name: "KeelIAP",
            dependencies: [
                "KeelServer",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: strictSettings
        ),
        .target(
            name: "KeelIAPDynamoDB",
            dependencies: [
                "KeelIAP",
                "SotoDynamoDB",
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: strictSettings
        ),
        .target(
            name: "KeelIAPRouter",
            dependencies: [
                "KeelIAP",
                "KeelServer",
                .product(name: "Routing", package: "lambda-kit"),
                .product(name: "AWSLambdaEvents", package: "swift-aws-lambda-events"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "KeelIAPTests",
            dependencies: [
                "KeelIAP",
                "KeelServer",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: strictSettings
        ),
        .executableTarget(
            name: "keel-cli",
            dependencies: [
                "KeelServer",
                "KeelServerDynamoDB",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: strictSettings
        ),
    ]
)

import ArgumentParser
import KeelServer
import KeelServerDynamoDB
import SotoDynamoDB

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif

/// The admin CLI. Three verbs, all against the deployed table — this is the control surface
/// `docs/ARCHITECTURE.md` §7 promises: flags, gate, and the telemetry kill switch change here,
/// live within one cache TTL, with no deploy.
///
/// ```
/// keel config get --table myapp-prod
/// keel config set telemetry.enabled false --table myapp-prod
/// keel config replace --file config.json --table myapp-prod
/// keel stats dump --table myapp-prod
/// ```
@main
struct KeelCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "keel",
        abstract: "Administer a Keel backend.",
        subcommands: [ConfigCommand.self, StatsCommand.self])
}

/// `--table` and `--region`, shared by every subcommand.
struct TableOptions: ParsableArguments {
    @Option(help: "Name of the Keel DynamoDB table.")
    var table: String

    @Option(help: "AWS region. Defaults to the environment's (AWS_REGION, profile).")
    var region: String?

    /// Runs `body` with a configured store pair, shutting the client down afterwards —
    /// `AWSClient` requires an explicit shutdown outside a Lambda.
    func withStores<T: Sendable>(
        _ body: (DynamoDBCounterStore, DynamoDBConfigStore) async throws -> T
    ) async throws -> T {
        let client = AWSClient()
        let resolvedRegion: Region? =
            if let region {
                Region(awsRegionName: region)
            } else if let env = ProcessInfo.processInfo.environment["AWS_REGION"]
                ?? ProcessInfo.processInfo.environment["AWS_DEFAULT_REGION"]
            { Region(awsRegionName: env) } else { nil }
        let dynamoDB = DynamoDB(client: client, region: resolvedRegion)
        do {
            let result = try await body(
                DynamoDBCounterStore(dynamoDB: dynamoDB, tableName: table),
                DynamoDBConfigStore(dynamoDB: dynamoDB, tableName: table))
            try await client.shutdown()
            return result
        } catch {
            try? await client.shutdown()
            throw error
        }
    }
}

// MARK: - keel config

struct ConfigCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Read and write the remote configuration item.",
        subcommands: [Get.self, Set.self, Replace.self])

    struct Get: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print the stored configuration as JSON.")

        @OptionGroup var options: TableOptions

        func run() async throws {
            let config = try await options.withStores { _, configs in
                try await configs.load()
            }
            guard let config else {
                // Not an error: an empty table is the normal state of a fresh stack, and the
                // backend behaves as `.empty` — worth saying in the same shape a set would take.
                print(try Self.rendered(RemoteConfig.empty))
                // The note goes to stderr so `keel config get | jq` still parses.
                // Written through the POSIX fd (2) rather than the C `stderr` global,
                // which is a non-concurrency-safe `var` under Swift 6 strict concurrency
                // on Linux — and `FileHandle` is absent when Linux imports
                // FoundationEssentials rather than full Foundation.
                Self.writeStderr("(no config item stored; showing the empty defaults)\n")
                return
            }
            print(try Self.rendered(config))
        }

        static func rendered(_ config: RemoteConfig) throws -> String {
            String(decoding: try WireJSON.encoder(pretty: true).encode(config), as: UTF8.self)
        }

        /// Write a note to stderr via the POSIX fd (2). Avoids the C `stderr` global,
        /// which is a non-concurrency-safe `var` on Linux, and works whether the file
        /// imports full Foundation or FoundationEssentials.
        static func writeStderr(_ message: String) {
            let bytes = Array(message.utf8)
            bytes.withUnsafeBytes { buffer in
                var written = 0
                while written < buffer.count {
                    let n = write(
                        2, buffer.baseAddress!.advanced(by: written), buffer.count - written)
                    if n <= 0 { break }
                    written += n
                }
            }
        }
    }

    struct Set: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Set one value by key path — `keel config set telemetry.enabled false`.")

        @Argument(help: "Dot-separated path into the config JSON, e.g. telemetry.enabled.")
        var keyPath: String

        @Argument(
            help: "The new value, read as JSON: true, false, a number, null, or a bare string.")
        var value: String

        @OptionGroup var options: TableOptions

        func run() async throws {
            try await options.withStores { _, configs in
                let current = try await configs.load() ?? .empty

                // Read-modify-write through `JSONValue` and back, so the CLI needs no setter
                // per field — and decoding the result back into `RemoteConfig` is what
                // validates the edit before anything is stored.
                let encoded = try WireJSON.encoder().encode(current)
                var tree = try WireJSON.decoder().decode(JSONValue.self, from: encoded)
                tree = tree.setting(
                    path: keyPath.split(separator: ".").map(String.init),
                    to: JSONValue(literal: value))

                let updated = try WireJSON.decoder().decode(
                    RemoteConfig.self, from: WireJSON.encoder().encode(tree))
                try await configs.save(updated)
                print(try Get.rendered(updated))
            }
        }
    }

    struct Replace: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Replace the whole configuration from a JSON file (or standard input).")

        @Option(help: "Path to the JSON file. Omit to read standard input.")
        var file: String?

        @OptionGroup var options: TableOptions

        func run() async throws {
            let data: Data
            if let file {
                data = try Data(contentsOf: URL(fileURLWithPath: file))
            } else {
                // `readLine` rather than `FileHandle`, which FoundationEssentials does not have
                // on Linux. The input is JSON, so line-oriented reading loses nothing.
                var text = ""
                while let line = readLine(strippingNewline: false) { text += line }
                data = Data(text.utf8)
            }
            // Decoded before anything touches the table: a mistyped file must fail here, not
            // half-apply. Tolerant decoding still applies — an unknown key is ignored, which is
            // the same forgiveness the Lambda extends.
            let config = try WireJSON.decoder().decode(RemoteConfig.self, from: data)
            try await options.withStores { _, configs in
                try await configs.save(config)
            }
            print(try Get.rendered(config))
        }
    }
}

// MARK: - keel stats

struct StatsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stats",
        abstract: "Read the published aggregates.",
        subcommands: [Dump.self])

    struct Dump: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print exactly what GET /v1/stats would return, pretty-printed.")

        @Option(help: "Trailing days of DAU to include.")
        var days: Int = 30

        @Option(help: "Trailing months of MAU to include.")
        var months: Int = 12

        @OptionGroup var options: TableOptions

        func run() async throws {
            let response = try await options.withStores { counters, configs in
                try await StatsHandler(
                    store: counters,
                    cache: ConfigCache(store: configs),
                    dauWindowDays: days,
                    mauWindowMonths: months
                ).handle()
            }
            print(
                String(
                    decoding: try WireJSON.encoder(pretty: true).encode(response), as: UTF8.self))
        }
    }
}

// MARK: - JSON editing

extension JSONValue {
    /// The CLI's reading of a bare argument: JSON scalars first, bare string as the fallback.
    ///
    /// `true`, `false`, `null`, and numbers mean their JSON selves; anything else is a string,
    /// so URLs and flag names need no shell-quoted quotes. A string that *looks* like a number
    /// cannot be spelled — no Keel config field wants one, and the ambiguity would otherwise
    /// bite the common case.
    init(literal: String) {
        switch literal {
        case "true": self = .bool(true)
        case "false": self = .bool(false)
        case "null": self = .null
        default:
            if let int = Int(literal) {
                self = .int(int)
            } else if let double = Double(literal) {
                self = .double(double)
            } else {
                self = .string(literal)
            }
        }
    }

    /// This value with `path` set to `newValue`, creating intermediate objects as needed.
    ///
    /// Setting a path through a non-object replaces it — `keel config set gate.minSupportedVersion`
    /// on a config whose `gate` is null creates the object, which is what the caller meant.
    func setting(path: [String], to newValue: JSONValue) -> JSONValue {
        guard let key = path.first else { return newValue }
        var object: [String: JSONValue] =
            if case .object(let existing) = self { existing } else { [:] }
        let child = object[key] ?? .object([:])
        object[key] = child.setting(path: Array(path.dropFirst()), to: newValue)
        return .object(object)
    }
}

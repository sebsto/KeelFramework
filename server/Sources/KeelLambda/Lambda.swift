import AWSLambdaEvents
import AWSLambdaRuntime
import Configuration
import KeelAppStore
import KeelAppStoreRouter
import KeelRouter
import KeelServer
import KeelServerDynamoDB
import KeelSotoDynamoDB
import Logging
import Routing

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// The ready-made Keel function: the three framework routes and nothing else, wired entirely
/// from the environment. Deploy it as-is; an app with routes of its own writes the same dozen
/// lines around `builder.mount(keel:)` in its own executable instead.
///
/// Deployment knobs come from `swift-configuration` reading the environment — see `Settings`.
/// Product configuration (flags, gate, URLs) is *not* here; it lives in the table so it can
/// change without a deploy (`docs/ARCHITECTURE.md` §7).
@main
struct KeelLambda: LambdaHandler {
    private let router: HTTPRouter

    init() throws {
        let settings = try Settings()
        var logger = Logger(label: "keel")
        logger.logLevel = settings.logLevel
        logger.info(
            "Initializing KeelLambda",
            metadata: ["table": .string(settings.tableName), "version": .string(Keel.version)])

        let builder = Self.makeRouterBuilder(settings: settings, logger: logger)
        self.router = builder.build()
    }

    func handle(
        _ event: APIGatewayV2Request, context: LambdaContext
    ) async throws -> APIGatewayV2Response {
        let response = await router.handle(HTTPRequest(event: event), logger: context.logger)
        return APIGatewayV2Response(
            statusCode: response.statusCode,
            headers: response.headers,
            body: response.body)
    }

    static func main() async throws {
        let handler = try KeelLambda()
        // The custom decoder is load-bearing: lambda-kit's router keys on the `proxy` path
        // parameter, which API Gateway sets only on `{proxy+}` routes. Keel's CDK declares
        // *explicit* routes — that is what makes per-route auth (`publicRoutes`) expressible —
        // so the decoder synthesizes `proxy` from `rawPath` before the event is typed.
        let runtime = LambdaRuntime(
            encoder: LambdaJSONOutputEncoder<APIGatewayV2Response>(JSONEncoder()),
            decoder: ProxySynthesizingDecoder(),
            body: handler.handle)
        try await runtime.run()
    }

    // MARK: - Router wiring

    /// Build the router for a Keel Lambda, registering the framework routes and (when
    /// configured) the App Store notification route.
    ///
    /// This is the reference wiring for an app that needs its own routes alongside Keel's.
    /// It is `internal` to this **executable** target, so an app cannot import or call it —
    /// an app reproduces these steps in its own `main.swift` against the framework's public
    /// **library** targets (`KeelServer` handlers + `ConfigCache`, `KeelServerDynamoDB` stores,
    /// and `KeelRouter` for the `KeelRouter` init and the `builder.mount(keel:)` seam):
    ///
    /// ```swift
    /// let keel = KeelRouter(bootstrap: …, ping: …, stats: …, corsConfig: …, logger: logger)
    /// let builder = HTTPRouterBuilder()
    /// builder.mount(keel: keel)
    /// builder.get("/v1/my-route") { request, _ in … }
    /// let router = builder.build()
    /// ```
    ///
    /// See `docs/INTEGRATION.md` §"App-owned routes" for the full worked example, and
    /// `AdopterSeamTests` for the compile-time guard that the seam stays importable.
    ///
    /// - Parameters:
    ///   - settings: Resolved deployment configuration (from the environment at cold start).
    ///   - logger: The function logger; entries are tagged with the route that produced them.
    /// - Returns: A configured builder with all Keel routes (and the App Store notification
    ///   route, when enabled) already mounted. Register additional routes, then call `.build()`.
    static func makeRouterBuilder(settings: Settings, logger: Logger) -> HTTPRouterBuilder {
        let counters: any CounterStore
        let configs: any ConfigStore
        #if DEBUG
        if settings.usesMemoryStore {
            // Local development only: `swift run KeelLambda` under `APIGatewayV2Server` with no
            // AWS account in sight. Debug builds only — the deployable release binary cannot be
            // talked into forgetting its table.
            logger.warning("KEEL_MEMORY_STORE is set — counters and config are in-process only")
            let store = MemoryStore()
            counters = store
            configs = store
        } else {
            (counters, configs) = dynamoDBStores(tableName: settings.tableName)
        }
        #else
        (counters, configs) = dynamoDBStores(tableName: settings.tableName)
        #endif

        let cache = ConfigCache(
            store: configs,
            ttl: Double(settings.configTTLSeconds),
            logger: logger)
        let keel = KeelRouter(
            bootstrap: BootstrapHandler(
                cache: cache,
                flagOverride: settings.flagOverride,
                logger: logger),
            ping: PingHandler(store: counters, cache: cache, logger: logger),
            stats: StatsHandler(
                store: counters,
                cache: cache,
                dauWindowDays: settings.dauWindowDays,
                mauWindowMonths: settings.mauWindowMonths,
                logger: logger),
            aliases: settings.aliases,
            corsConfig: CORSConfig(allowedOrigins: settings.allowedOrigins),
            bootstrapCacheSeconds: settings.configTTLSeconds,
            logger: logger)

        let builder = HTTPRouterBuilder()
        builder.mount(keel: keel)

        if let appStore = settings.appStoreNotifications {
            // Only apps that opted in get the route; everyone else's function has no App Store
            // surface to probe. This ready-made Lambda has no app-specific state to touch, so
            // its handler verifies the inner transaction against the configured bundle and the
            // product allowlist, then logs — an app with routes of its own writes its side
            // effect (grant, revoke, consumption report) in the closure in its own executable.
            let verifier = NotificationVerifier()
            builder.mount(appStore: verifier, logger: logger) { notification in
                guard let inner = notification.signedTransactionInfo else {
                    // No transaction to name (e.g. a TEST notification). Acknowledged.
                    return
                }
                let transaction = try await verifier.verifyTransactionInfo(inner)
                guard transaction.bundleId == appStore.bundleId else {
                    logger.error(
                        "Notification for a different bundle",
                        metadata: ["bundleId": .string(transaction.bundleId)])
                    return
                }
                // A JWS can verify and match the bundle yet name a product this backend does
                // not sell — a receipt for another app sharing the bundle, or a SKU we never
                // shipped. Pin it to the declared allowlist, the same check the transaction
                // verifier applied before the split.
                guard appStore.productIds.contains(transaction.productId) else {
                    logger.error(
                        "Notification for an unexpected product",
                        metadata: ["product": .string(transaction.productId)])
                    return
                }
                logger.info(
                    "Verified App Store notification",
                    metadata: [
                        "type": .string(notification.notificationType.rawValue),
                        "product": .string(transaction.productId),
                    ])
            }
            logger.info(
                "App Store notification route mounted",
                metadata: ["bundleId": .string(appStore.bundleId)])
        }

        return builder
    }

    /// One `AWSClient` per process, created at cold start and reused across invocations — it
    /// owns the connection pool, and rebuilding it per request would pay TLS setup on every
    /// ping. Region and credentials resolve from the execution environment.
    private static func dynamoDBStores(
        tableName: String
    ) -> (any CounterStore, any ConfigStore) {
        let dynamoDB = DynamoDB(client: AWSClient())
        return (
            DynamoDBCounterStore(dynamoDB: dynamoDB, tableName: tableName),
            DynamoDBConfigStore(dynamoDB: dynamoDB, tableName: tableName)
        )
    }
}

/// The deployment knobs, read once at cold start.
///
/// Every key is an environment variable set by the CDK construct
/// (`configTTLSeconds` → `CONFIG_TTL_SECONDS`, and so on). Each default matches what
/// `docs/ARCHITECTURE.md` documents, so an empty environment plus `TABLE_NAME` is a working
/// deployment.
struct Settings {
    let tableName: String
    let configTTLSeconds: Int
    let dauWindowDays: Int
    let mauWindowMonths: Int
    let aliases: AliasRoutes
    let flagOverride: FeatureFlagsOverride
    let logLevel: Logger.Level

    /// Present only when the deployment opted into App Store server notifications: the
    /// bundle id (pinned against the inner transaction) and the products the app sells. Both
    /// variables set, or neither — one without the other is a misconfiguration worth failing
    /// over.
    struct AppStoreNotifications {
        let bundleId: String
        let productIds: Set<String>
    }

    let appStoreNotifications: AppStoreNotifications?

    /// Origins the function will echo in `Access-Control-Allow-Origin`. Empty when the
    /// `ALLOWED_ORIGINS` environment variable is absent or blank — CORS is disabled by
    /// default and opt-in by setting the variable.
    let allowedOrigins: [String]

    #if DEBUG
    /// `KEEL_MEMORY_STORE=1` — serve from an in-process store, for local development against
    /// `APIGatewayV2Server`. Compiled out of release builds entirely.
    let usesMemoryStore: Bool
    #endif

    init(config: ConfigReader = ConfigReader(provider: EnvironmentVariablesProvider())) throws {
        // Missing on purpose has no meaning here, so it fails at init and the function never
        // comes up. A silent default pointing at a table that does not exist is the classic
        // orphan-table trap: it surfaces as "the stats are all zero" weeks later.
        guard let tableName = config.string(forKey: "tableName"), !tableName.isEmpty else {
            throw SettingsError.missingTableName
        }
        self.tableName = tableName
        self.configTTLSeconds = config.int(forKey: "configTTLSeconds", default: 60)
        self.dauWindowDays = config.int(forKey: "dauWindowDays", default: 30)
        self.mauWindowMonths = config.int(forKey: "mauWindowMonths", default: 12)
        self.aliases = AliasRoutes(environmentValue: config.string(forKey: "aliasRoutes"))
        self.flagOverride = FeatureFlagsOverride(
            environmentValue: config.string(forKey: "featureFlags"))
        self.logLevel =
            config.string(forKey: "logLevel").flatMap(Logger.Level.init(rawValue:)) ?? .info

        let appStoreBundleId = config.string(forKey: "appStoreBundleId")
        let appStoreProductIds = config.string(forKey: "appStoreProductIds")
        switch (appStoreBundleId, appStoreProductIds) {
        case (nil, nil):
            self.appStoreNotifications = nil
        case (let bundleId?, let products?):
            // Trimmed by hand: `trimmingCharacters(in:)` needs `CharacterSet`, which
            // `FoundationEssentials` does not ship on Linux.
            let ids = Set(
                products.split(separator: ",").map { entry in
                    String(
                        entry.drop(while: \.isWhitespace).reversed()
                            .drop(while: \.isWhitespace).reversed())
                }
            ).filter { !$0.isEmpty }
            guard !bundleId.isEmpty, !ids.isEmpty else {
                throw SettingsError.incompleteAppStoreConfiguration
            }
            self.appStoreNotifications = AppStoreNotifications(bundleId: bundleId, productIds: ids)
        default:
            // A bundle with no products verifies nothing; products with no bundle pin
            // nothing. Half a configuration is a deploy mistake, not a mode.
            throw SettingsError.incompleteAppStoreConfiguration
        }
        // Trim each entry the same way as iapProductIds: FoundationEssentials-safe,
        // no CharacterSet, no replacingOccurrences. An absent or blank variable leaves
        // CORS disabled (the default and the safe choice).
        self.allowedOrigins =
            config.string(forKey: "allowedOrigins").map { value in
                value.split(separator: ",").compactMap { entry in
                    let trimmed = String(
                        entry.drop(while: \.isWhitespace).reversed()
                            .drop(while: \.isWhitespace).reversed())
                    return trimmed.isEmpty ? nil : trimmed
                }
            } ?? []
        #if DEBUG
        self.usesMemoryStore = config.bool(forKey: "keelMemoryStore", default: false)
        #endif
    }
}

enum SettingsError: Error {
    /// `TABLE_NAME` is unset or empty. There is no default that would not be a trap.
    case missingTableName

    /// One of `APP_STORE_BUNDLE_ID` / `APP_STORE_PRODUCT_IDS` without the other, or either empty.
    case incompleteAppStoreConfiguration
}

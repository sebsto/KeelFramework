import AWSLambdaEvents
import AWSLambdaRuntime
import Configuration
import KeelIAP
import KeelIAPDynamoDB
import KeelIAPRouter
import KeelRouter
import KeelServer
import KeelServerDynamoDB
import Logging
import Routing
import SotoDynamoDB

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
            (counters, configs) = Self.dynamoDBStores(tableName: settings.tableName)
        }
        #else
        (counters, configs) = Self.dynamoDBStores(tableName: settings.tableName)
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
            bootstrapCacheSeconds: settings.configTTLSeconds,
            logger: logger)

        let builder = HTTPRouterBuilder()
        builder.mount(keel: keel)

        if let iap = settings.iap {
            // Only apps that opted in get the routes; everyone else's function has no
            // IAP surface to probe. The store shares the one table and the one client.
            let dynamoDB = DynamoDB(client: AWSClient())
            let entitlements = DynamoDBEntitlementStore(
                dynamoDB: dynamoDB, tableName: settings.tableName)
            builder.mount(
                keelIAP: KeelIAPRouter(
                    purchase: PurchaseHandler(
                        verifier: AppStoreJWSVerifier(
                            expectedBundleId: iap.bundleId,
                            knownProductIds: iap.productIds),
                        store: entitlements,
                        logger: logger),
                    entitlement: EntitlementHandler(store: entitlements),
                    notification: NotificationHandler(
                        verifier: NotificationVerifier(),
                        store: entitlements,
                        expectedBundleId: iap.bundleId,
                        logger: logger)))
            logger.info("IAP routes mounted", metadata: ["bundleId": .string(iap.bundleId)])
        }

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

    /// Present only when the deployment opted into server-side IAP: both variables set,
    /// or neither — one without the other is a misconfiguration worth failing over.
    struct IAP {
        let bundleId: String
        let productIds: Set<String>
    }

    let iap: IAP?

    #if DEBUG
    /// `KEEL_MEMORY_STORE=1` — serve from an in-process store, for local development against
    /// `APIGatewayV2Server`. Compiled out of release builds entirely.
    let usesMemoryStore: Bool
    #endif

    init(config: ConfigReader = ConfigReader(provider: EnvironmentVariablesProvider())) throws {
        // Missing on purpose has no meaning here, so it fails at init and the function never
        // comes up — a silent default pointing at a table that does not exist is odvpn's
        // orphan-table trap, and it surfaces as "the stats are all zero" weeks later.
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

        let iapBundleId = config.string(forKey: "iapBundleId")
        let iapProductIds = config.string(forKey: "iapProductIds")
        switch (iapBundleId, iapProductIds) {
        case (nil, nil):
            self.iap = nil
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
                throw SettingsError.incompleteIAPConfiguration
            }
            self.iap = IAP(bundleId: bundleId, productIds: ids)
        default:
            // A bundle with no products verifies nothing; products with no bundle pin
            // nothing. Half a configuration is a deploy mistake, not a mode.
            throw SettingsError.incompleteIAPConfiguration
        }
        #if DEBUG
        self.usesMemoryStore = config.bool(forKey: "keelMemoryStore", default: false)
        #endif
    }
}

enum SettingsError: Error {
    /// `TABLE_NAME` is unset or empty. There is no default that would not be a trap.
    case missingTableName

    /// One of `IAP_BUNDLE_ID` / `IAP_PRODUCT_IDS` without the other, or either empty.
    case incompleteIAPConfiguration
}

import AWSLambdaEvents
import Foundation
import HTTPTypes
import KeelServerTesting
import Logging
import Routing
import Testing
@testable import KeelRouter
@testable import KeelServer

/// Tests for the app-owned-routes seam: an app can register routes alongside Keel's on
/// the same `HTTPRouterBuilder`, and both kinds of routes are served correctly.
///
/// The seam itself is `builder.mount(keel:)` followed by arbitrary `builder.get(...)` calls,
/// all collected by the same `HTTPRouterBuilder` and served by the resulting `HTTPRouter`.
/// This is the pattern documented in `docs/INTEGRATION.md §"App-owned routes"`.
///
/// The test operates entirely with in-memory stores — no DynamoDB, no Lambda runtime.
/// `HTTPRequest` objects are decoded from minimal JSON events, matching how the Lambda
/// runtime constructs them from real API Gateway payloads.
@Suite("Router seam — app-owned routes alongside Keel routes")
struct RouterSeamTests {

    // MARK: - Fixtures

    /// A fully wired Keel router backed by in-memory fakes.
    private static func makeKeelRouter() -> KeelRouter {
        let store = InMemoryCounterStore()
        let configStore = InMemoryConfigStore()
        var logger = Logger(label: "test")
        logger.logLevel = .critical  // keep test output clean
        let cache = ConfigCache(store: configStore, ttl: 60, logger: logger)
        return KeelRouter(
            bootstrap: BootstrapHandler(cache: cache, flagOverride: .none, logger: logger),
            ping: PingHandler(store: store, cache: cache, logger: logger),
            stats: StatsHandler(
                store: store, cache: cache, dauWindowDays: 30, mauWindowMonths: 12,
                logger: logger),
            logger: logger)
    }

    // MARK: - Seam tests

    @Test("Keel routes are reachable on a builder that also has an app route")
    func keelRoutesReachableAlongsideAppRoute() async throws {
        let builder = HTTPRouterBuilder()
        builder.mount(keel: Self.makeKeelRouter())
        // An app-specific route registered after mounting Keel — must not disturb Keel's table
        builder.get("/artwork") { _, _ in
            RouteResponse.json(["status": "ok"], statusCode: .ok)
        }
        let router = builder.build()

        // A Keel route (GET /v1/stats) must still respond correctly
        let statsResp = await router.handle(
            try makeGETRequest(path: "/v1/stats"),
            logger: Logger(label: "t"))
        #expect(statsResp.statusCode.code == 200)
    }

    @Test("App-owned route is reachable when mounted alongside Keel routes")
    func appRouteReachableAlongsideKeelRoutes() async throws {
        let builder = HTTPRouterBuilder()
        builder.mount(keel: Self.makeKeelRouter())
        builder.get("/artwork") { _, _ in
            RouteResponse.json(["name": "Mona Lisa"], statusCode: .ok)
        }
        let router = builder.build()

        let resp = await router.handle(
            try makeGETRequest(path: "/artwork"),
            logger: Logger(label: "t"))
        #expect(resp.statusCode.code == 200)
    }

    @Test("App-owned route does not shadow or disturb Keel's bootstrap route")
    func appRouteDoesNotShadowBootstrap() async throws {
        let builder = HTTPRouterBuilder()
        builder.mount(keel: Self.makeKeelRouter())
        // A separate app route on a different path — must not collide
        builder.get("/v1/my-feature") { _, _ in
            RouteResponse.json(["ok": true], statusCode: .ok)
        }
        let router = builder.build()

        let bootstrapResp = await router.handle(
            try makeGETRequest(path: "/v1/bootstrap"),
            logger: Logger(label: "t"))
        #expect(bootstrapResp.statusCode.code == 200)

        let myResp = await router.handle(
            try makeGETRequest(path: "/v1/my-feature"),
            logger: Logger(label: "t"))
        #expect(myResp.statusCode.code == 200)
    }

    @Test("Multiple app-owned routes coexist and each is independently reachable")
    func multipleAppRoutesCoexist() async throws {
        let builder = HTTPRouterBuilder()
        builder.mount(keel: Self.makeKeelRouter())
        // Three app routes representative of the Orthanc stripe integration pattern
        builder.get("/artwork") { _, _ in
            RouteResponse.json(["route": "artwork"], statusCode: .ok)
        }
        builder.get("/v1/checkout") { _, _ in
            RouteResponse.json(["route": "checkout"], statusCode: .ok)
        }
        builder.get("/v1/license") { _, _ in
            RouteResponse.json(["route": "license"], statusCode: .ok)
        }
        let router = builder.build()

        for path in ["/artwork", "/v1/checkout", "/v1/license"] {
            let resp = await router.handle(
                try makeGETRequest(path: path),
                logger: Logger(label: "t"))
            #expect(resp.statusCode.code == 200, "Expected 200 for \(path)")
        }

        // Keel's own routes are unaffected
        let statsResp = await router.handle(
            try makeGETRequest(path: "/v1/stats"),
            logger: Logger(label: "t"))
        #expect(statsResp.statusCode.code == 200)
    }
}

// MARK: - Helpers

/// Build a GET `HTTPRequest` for a given path by decoding a minimal API Gateway V2
/// JSON event. This mirrors how the Lambda runtime constructs requests from real
/// API Gateway payloads — the router's `routingKey` computation reads `pathParameters["proxy"]`,
/// which the `ProxySynthesizingDecoder` in `KeelLambda` normally fills in from `rawPath`.
/// Here we fill it directly in the JSON payload.
private func makeGETRequest(path: String) throws -> Routing.HTTPRequest {
    // Strip the leading "/" for the proxy parameter value — API Gateway sets
    // the "proxy" parameter to the path without the leading slash.
    let proxy = path.hasPrefix("/") ? String(path.dropFirst()) : path

    let json = """
        {
          "version": "2.0",
          "routeKey": "GET \(path)",
          "rawPath": "\(path)",
          "rawQueryString": "",
          "isBase64Encoded": false,
          "headers": { "host": "test.example.com" },
          "pathParameters": { "proxy": "\(proxy)" },
          "requestContext": {
            "accountId": "123456789012",
            "apiId": "test",
            "stage": "$default",
            "domainName": "test.example.com",
            "domainPrefix": "test",
            "requestId": "test-request-id",
            "time": "02/Sep/2026:10:00:00 +0000",
            "timeEpoch": 1756792800000,
            "http": {
              "method": "GET",
              "path": "\(path)",
              "protocol": "HTTP/1.1",
              "sourceIp": "127.0.0.1",
              "userAgent": "TestSuite/1.0"
            }
          }
        }
        """
    let event = try JSONDecoder().decode(APIGatewayV2Request.self, from: Data(json.utf8))
    return Routing.HTTPRequest(event: event)
}

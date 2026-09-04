// PLAIN imports only — deliberately NO `@testable`. This file is the compile-time proof
// that an app adopting Keel can build a router using only the PUBLIC library API an adopter
// could depend on: the handlers + `ConfigCache` from `KeelServer`, the in-memory stores from
// `KeelServerTesting` (an adopter uses these in its own tests; in production it swaps in
// `KeelServerDynamoDB`), and `KeelRouter` + `builder.mount(keel:)` from `KeelRouter`.
//
// It imports NONE of the `KeelLambda` executable target, by design: an executable target's
// symbols (such as a `makeRouterBuilder` helper) are `internal` and cannot be imported by an
// adopter, so the seam an adopter actually builds against must live in a library. If a future
// change strands the seam that way — by making `KeelRouter`'s init or `mount(keel:)` non-public,
// or moving a handler out of a library — this file stops compiling, which is a louder failure
// than a stale doc.
import AWSLambdaEvents
import Foundation
import HTTPTypes
import KeelRouter
import KeelServer
import KeelServerTesting
import Logging
import Routing
import Testing

@Suite("Adopter seam — router built with public library API only")
struct AdopterSeamTests {

    /// Build a Keel router the way an adopter would: public init, public handlers, a public
    /// store. No `@testable`, no executable-target import.
    private static func makeKeelRouter() -> KeelRouter {
        var logger = Logger(label: "adopter")
        logger.logLevel = .critical
        let cache = ConfigCache(store: InMemoryConfigStore(), ttl: 60, logger: logger)
        let counters = InMemoryCounterStore()
        return KeelRouter(
            bootstrap: BootstrapHandler(cache: cache, flagOverride: .none, logger: logger),
            ping: PingHandler(store: counters, cache: cache, logger: logger),
            stats: StatsHandler(
                store: counters, cache: cache, dauWindowDays: 30, mauWindowMonths: 12,
                logger: logger),
            corsConfig: CORSConfig(allowedOrigins: ["https://example.com"]),
            logger: logger)
    }

    @Test("An adopter mounts Keel and its own route on one builder, using only public API")
    func adopterBuildsRouterViaPublicSeam() async throws {
        let builder = HTTPRouterBuilder()
        builder.mount(keel: Self.makeKeelRouter())  // the documented, importable seam
        builder.get("/artwork") { _, _ in  // the adopter's own route
            RouteResponse.json(["status": "ok"], statusCode: .ok)
        }
        let router = builder.build()

        // Both the adopter route and a Keel route resolve on the same router.
        let appResp = await router.handle(
            try Self.makeGetRequest(path: "/artwork"), logger: Logger(label: "t"))
        #expect(appResp.statusCode.code == 200)

        let keelResp = await router.handle(
            try Self.makeGetRequest(path: "/v1/stats"), logger: Logger(label: "t"))
        #expect(keelResp.statusCode.code == 200)
    }

    /// Minimal API Gateway V2 GET event, decoded to a `Routing.HTTPRequest` the way the
    /// Lambda runtime constructs one. Kept local so this file depends on nothing but the
    /// public libraries above.
    private static func makeGetRequest(path: String) throws -> Routing.HTTPRequest {
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
}

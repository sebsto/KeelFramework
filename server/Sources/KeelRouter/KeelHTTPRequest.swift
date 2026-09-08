public import AWSLambdaEvents
import HTTPTypes
public import Logging
public import Routing
public import RoutingKit

#if canImport(FoundationEssentials)
public import FoundationEssentials
#else
public import Foundation
#endif

// MARK: - KeelHTTPRequest

/// The request type Keel routes on: a `Routable` for a backend whose routes are declared
/// **explicitly** on the API Gateway, keyed on the path the gateway actually populates.
///
/// `Routing.HTTPRequest` derives its routing key from `pathParameters["proxy"]`, which API
/// Gateway sets only for a greedy `/{proxy+}` route. `KeelBackend` registers explicit routes
/// (`GET /v1/stats`, …) so that `publicRoutes` can be expressed as "no authorizer attached"
/// rather than "an authorizer that waves the request through" (`docs/ARCHITECTURE.md` §8).
/// On an explicit route that parameter is absent, so lambda-kit's key collapses to the method
/// alone and every request 404s. This type reads `event.context.http.path` instead — the path
/// the gateway populates for an explicit route — and dispatches on that.
///
/// lambda-kit's router is generic over `Routable`; only its `HTTPRequest` convenience type
/// bakes in the `{proxy+}` assumption. So Keel supplies its own conformer and specialises the
/// *same* generic `Router` (`KeelHTTPRouter`), reusing the trie engine, middleware, body
/// decoding and route groups unchanged. It cannot be done by extending `HTTPRequest`:
/// `routingKey` resolves statically inside lambda-kit, so a same-named extension in another
/// module is ignored — the request type itself has to change.
///
/// The public surface mirrors `Routing.HTTPRequest` (`event`, `headers`, `queryParameters`,
/// `body`, and `@dynamicMemberLookup` forwarding), so an adopter migrating from the lambda-kit
/// type changes the request name and nothing else.
@dynamicMemberLookup
public struct KeelHTTPRequest: Routable {
    /// The underlying AWS Lambda event. Reach for this to read fields not surfaced as a typed
    /// convenience below.
    public let event: APIGatewayV2Request

    /// Path parameters matched by the router during trie lookup. Mutable because the router
    /// writes into this slot after a successful match.
    public var pathParameters: PathParameters

    /// Query string parameters, parsed into the typed `QueryParameters` API.
    public let queryParameters: QueryParameters

    /// HTTP headers via the case-insensitive `Headers` API, so a caller need not know whether
    /// the gateway sent `Host` or `host`.
    public let headers: Headers

    /// The request body. Base64-encoded payloads are decoded **once** here — Stripe-style
    /// webhook signatures are computed over the delivered bytes, so nothing downstream may
    /// re-encode or re-serialize it.
    public let body: Data

    public init(event: APIGatewayV2Request) {
        self.event = event
        self.pathParameters = .init()
        self.queryParameters = QueryParameters(values: event.queryStringParameters)
        self.headers = Headers(values: event.headers)
        if event.isBase64Encoded, let encoded = event.body {
            self.body = Data(base64Encoded: encoded) ?? .init()
        } else {
            self.body = event.body.flatMap { $0.data(using: .utf8) } ?? .init()
        }
    }

    /// The trie key this request dispatches on.
    ///
    /// Reads `event.context.http.path` rather than the `proxy` path parameter. `context.http.path`
    /// rather than `rawPath`: the two agree on the `$default` stage `KeelBackend` deploys, but
    /// `rawPath` carries the stage prefix on a named stage, which would push every route off by
    /// one segment.
    public var routingKey: [String] {
        Self.route(method: event.context.http.method.rawValue, path: event.context.http.path)
    }

    /// Forward member access to the underlying AWS event, so `request.context`, `request.rawPath`
    /// and the rest of the event surface read through. The stored properties above take
    /// precedence over this subscript.
    public subscript<T>(dynamicMember keyPath: KeyPath<APIGatewayV2Request, T>) -> T {
        event[keyPath: keyPath]
    }
}

// MARK: - Routing key convention

extension KeelHTTPRequest {
    /// The single source of truth for how a method + path becomes a trie key. Both registration
    /// (via the `get`/`post`/… factories) and dispatch (via `routingKey`) go through here, so the
    /// two sides cannot drift apart.
    ///
    /// Splitting on `/` and dropping empty components means the two path forms normalise to the
    /// same key: a `proxy`-style value (`v1/stats`, no leading slash) and a `context.http.path`
    /// value (`/v1/stats`, with one) both yield `["v1", "stats"]`.
    public static func route(method: String, path: String) -> [String] {
        [method] + path.split(separator: "/").map(String.init)
    }

    /// Build a routing key for a `GET` route.
    public static func get(_ path: String) -> [String] { route(method: "GET", path: path) }

    /// Build a routing key for a `POST` route.
    public static func post(_ path: String) -> [String] { route(method: "POST", path: path) }

    /// Build a routing key for a `DELETE` route.
    public static func delete(_ path: String) -> [String] { route(method: "DELETE", path: path) }

    /// Build a routing key for a `PUT` route.
    public static func put(_ path: String) -> [String] { route(method: "PUT", path: path) }

    /// Build a routing key for a `PATCH` route.
    public static func patch(_ path: String) -> [String] { route(method: "PATCH", path: path) }
}

// MARK: - Router specialisation

/// A `RouterBuilder` specialised for `KeelHTTPRequest`, backed by the same `TrieRouter` engine
/// lambda-kit uses for HTTP. This is the Keel counterpart of `Routing.HTTPRouterBuilder`.
public typealias KeelHTTPRouterBuilder = Routing.RouterBuilder<
    KeelHTTPRequest, TrieRouterBuilder<RouteHandler<KeelHTTPRequest>>
>

/// The immutable, `Sendable` router produced by `KeelHTTPRouterBuilder.build()`.
public typealias KeelHTTPRouter = Routing.Router<KeelHTTPRequest>

// MARK: - Convenience init + call-site sugar

extension Routing.RouterBuilder
where R == KeelHTTPRequest, Engine == TrieRouterBuilder<RouteHandler<KeelHTTPRequest>> {
    /// Construct a Keel HTTP router builder backed by a default `TrieRouter` engine.
    public convenience init() {
        self.init(engine: TrieRouterBuilder())
    }

    /// Register a `GET` handler at `path`.
    public func get(
        _ path: String,
        use handler: @Sendable @escaping (KeelHTTPRequest, Logger) async throws -> RouteResponse
    ) {
        on(KeelHTTPRequest.get(path), use: handler)
    }

    /// Register a `POST` handler at `path`.
    public func post(
        _ path: String,
        use handler: @Sendable @escaping (KeelHTTPRequest, Logger) async throws -> RouteResponse
    ) {
        on(KeelHTTPRequest.post(path), use: handler)
    }
}

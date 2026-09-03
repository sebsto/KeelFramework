import AWSLambdaEvents
import HTTPTypes
public import KeelServer
public import Logging
public import Routing

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// MARK: - CORSConfig

/// CORS policy for the Keel backend: echo-the-allowlist, never wildcard.
///
/// Rules enforced here match what browsers require for a non-simple cross-origin request:
/// - Only origins that appear in `allowedOrigins` get a CORS response.
/// - An absent or non-matching `Origin` header produces no CORS headers at all.
/// - Wildcard (`*`) is never emitted; echoing the specific origin lets browsers
///   send credentialed requests when needed.
/// - `Vary: Origin` is always included so caches do not serve a response destined
///   for one origin to a different one.
///
/// Apex and www are treated as distinct origins — add both if the app is reachable
/// under both names.
public struct CORSConfig: Sendable {
    /// Origins the server will echo back in `Access-Control-Allow-Origin`.
    /// An empty list disables CORS entirely.
    public let allowedOrigins: [String]

    /// No CORS headers are ever emitted.
    public static let disabled = CORSConfig(allowedOrigins: [])

    public init(allowedOrigins: [String]) {
        self.allowedOrigins = allowedOrigins
    }

    /// Returns the origin to echo if it is in the allowlist, otherwise `nil`.
    ///
    /// A `nil` return means no `Access-Control-Allow-Origin` header should be set.
    public func match(_ origin: String?) -> String? {
        guard let origin, !allowedOrigins.isEmpty else { return nil }
        return allowedOrigins.contains(origin) ? origin : nil
    }
}

// MARK: - KeelRouter

/// The framework's route table: the three canonical endpoints plus any declared aliases, ready
/// to mount on a lambda-kit `HTTPRouterBuilder`.
///
/// ```swift
/// let builder = HTTPRouterBuilder()
/// builder.mount(keel: keel)
/// builder.get("/artwork") { … }   // the app's own routes, same function
/// let router = builder.build()
/// ```
///
/// This target is the only library that imports `Routing` — the handlers are plain functions
/// and know nothing about HTTP, so replacing the router someday touches this module and the
/// executable, nothing else (`docs/adr/0002-lambda-kit-fork.md`).
///
/// Everything interesting — validation, projection, failure policy — happens in the handlers.
/// What this type owns is the *edge* decisions: which path runs which handler, what
/// `Cache-Control` each response carries, how a `KeelError` becomes a status code, and
/// which cross-origin requests are allowed.
public struct KeelRouter: Sendable {
    let bootstrap: BootstrapHandler
    let ping: PingHandler
    let stats: StatsHandler
    let aliases: AliasRoutes

    /// Seconds of `Cache-Control: public, max-age=…` on bootstrap responses. Short, because the
    /// kill switch rides this response; keep it aligned with `ConfigCache`'s TTL so a config
    /// change lands within one, not two, cache windows.
    let bootstrapCacheSeconds: Int

    /// Seconds on stats responses. Longer: the numbers move slowly and the edge cache is what
    /// lets the endpoint stay public without the table paying per curious reader.
    let statsCacheSeconds: Int

    let corsConfig: CORSConfig
    let logger: Logger

    public init(
        bootstrap: BootstrapHandler,
        ping: PingHandler,
        stats: StatsHandler,
        aliases: AliasRoutes = .none,
        corsConfig: CORSConfig = .disabled,
        bootstrapCacheSeconds: Int = 60,
        statsCacheSeconds: Int = 300,
        logger: Logger = Logger(label: "keel.router")
    ) {
        self.bootstrap = bootstrap
        self.ping = ping
        self.stats = stats
        self.aliases = aliases
        self.corsConfig = corsConfig
        self.bootstrapCacheSeconds = bootstrapCacheSeconds
        self.statsCacheSeconds = statsCacheSeconds
        self.logger = logger
        if !aliases.malformedEntries.isEmpty {
            // Once at construction, like the flag override: the variable cannot change for the
            // life of the function. Louder than the flags warning because the stakes are — a
            // dropped alias is a shipped client's route answering 404.
            logger.error(
                "Ignoring malformed \(AliasRoutes.environmentKey) entries — those paths will 404",
                metadata: [
                    "entries": .string(aliases.malformedEntries.joined(separator: ", "))
                ])
        }
    }

    /// Register every route on `builder`. Called via `builder.mount(keel:)`.
    func register(on builder: HTTPRouterBuilder) {
        register(
            route: .bootstrap, at: Keel.Route.bootstrap.rawValue, envelope: .standard, on: builder)
        register(route: .ping, at: Keel.Route.ping.rawValue, envelope: .standard, on: builder)
        register(route: .stats, at: Keel.Route.stats.rawValue, envelope: .standard, on: builder)
        for alias in aliases.aliases {
            register(route: alias.target, at: alias.path, envelope: alias.envelope, on: builder)
        }
        // OPTIONS preflight routes are only registered when CORS is configured. An OPTIONS
        // on a path that has no registered handler falls through to a 404 from API Gateway —
        // that is the correct behaviour for a non-CORS path (spec §7.1.6).
        if !corsConfig.allowedOrigins.isEmpty {
            registerPreflight(at: Keel.Route.bootstrap.rawValue, methods: "GET", on: builder)
            registerPreflight(at: Keel.Route.ping.rawValue, methods: "POST", on: builder)
            registerPreflight(at: Keel.Route.stats.rawValue, methods: "GET", on: builder)
            for alias in aliases.aliases {
                let method: String
                switch alias.target {
                case .ping: method = "POST"
                default: method = "GET"
                }
                registerPreflight(at: alias.path, methods: method, on: builder)
            }
        }
    }

    private func register(
        route: Keel.Route,
        at path: String,
        envelope: AliasRoutes.Envelope,
        on builder: HTTPRouterBuilder
    ) {
        switch route {
        case .bootstrap:
            builder.get(path) { request, _ in
                try await self.handleBootstrap(request, envelope: envelope)
            }
        case .ping:
            builder.on(Routing.HTTPRequest.post(path)) { request, _ in
                await self.handlePing(request)
            }
        case .stats:
            builder.get(path) { request, _ in
                await self.handleStats(request)
            }
        }
    }

    /// Request headers a browser is allowed to send on a preflighted cross-origin request.
    ///
    /// Beyond `Content-Type`/`Authorization`, this lists the SigV4 headers an AWS_IAM route
    /// requires. `registerPreflight` is registered for `/v1/ping` (an `AWS_IAM` route), so a
    /// browser client that signs requests with SigV4 — long-lived or, via `X-Amz-Security-Token`,
    /// temporary credentials — must be able to send `X-Amz-Date` and friends to clear preflight.
    /// Omitting them would make the preflight we register for the IAM route unusable from a
    /// browser. `X-Amz-Content-Sha256` is included because AWS SDK signers commonly send it even
    /// though Keel's own reference transport does not sign it. Header-name matching is
    /// case-insensitive per the Fetch spec, so the casing here is only cosmetic.
    static let preflightAllowHeaders =
        "Content-Type, Authorization, X-Amz-Date, X-Amz-Security-Token, X-Amz-Content-Sha256"

    /// Register an OPTIONS handler at `path` for the CORS preflight flow.
    ///
    /// The handler echoes the request `Origin` only if it is in the allowlist. An unknown
    /// or disallowed origin returns a bare 403 with no CORS headers — the browser will see
    /// the preflight fail and will not send the real request.
    ///
    /// `request.headers` is lambda-kit's case-insensitive `Headers` type (names are normalized
    /// to lowercase on both insertion and lookup), so the lowercase `"origin"` key matches a
    /// browser's capitalized `Origin` header. This is unlike `KeelAuthorizerLambda`, which reads
    /// the raw `[String: String]` authorizer event and therefore needs its dual-case lookup.
    private func registerPreflight(
        at path: String, methods: String, on builder: HTTPRouterBuilder
    ) {
        builder.on(Routing.HTTPRequest.route(method: "OPTIONS", path: path)) { request, _ in
            guard let matched = self.corsConfig.match(request.headers["origin"]) else {
                // Not in the allowlist: refuse without leaking which origins are allowed.
                return .empty(statusCode: .forbidden)
            }
            return .empty(
                statusCode: .ok,
                headers: [
                    "Access-Control-Allow-Origin": matched,
                    "Vary": "Origin",
                    "Access-Control-Allow-Methods": "\(methods), OPTIONS",
                    "Access-Control-Allow-Headers": Self.preflightAllowHeaders,
                ])
        }
    }

    // MARK: - Edge adapters

    private func handleBootstrap(
        _ request: Routing.HTTPRequest, envelope: AliasRoutes.Envelope
    ) async throws -> RouteResponse {
        let response = await bootstrap.handle(
            BootstrapHandler.Request(query: request.event.queryStringParameters))
        var headers = corsHeaders(for: request)
        headers["Cache-Control"] = "public, max-age=\(bootstrapCacheSeconds)"
        switch envelope {
        case .standard:
            return .json(response, statusCode: .ok, headers: headers)
        case .flattened:
            return .json(try response.flattened(), statusCode: .ok, headers: headers)
        }
    }

    private func handlePing(_ request: Routing.HTTPRequest) async -> RouteResponse {
        let cors = corsHeaders(for: request)
        let body: PingRequest
        do {
            body = try WireJSON.decoder().decode(PingRequest.self, from: request.body)
        } catch {
            // The decode error's own description can quote the body, and `docs/PRIVACY.md`
            // promises request bodies are never echoed or logged — so the client gets the
            // field-free version and the log gets nothing.
            return Self.response(
                for: .badRequest(field: "body", reason: "not a valid ping request"),
                headers: cors)
        }
        do {
            return .json(try await ping.handle(body), statusCode: .ok, headers: cors)
        } catch {
            return Self.response(for: error, headers: cors)
        }
    }

    private func handleStats(_ request: Routing.HTTPRequest) async -> RouteResponse {
        var headers = corsHeaders(for: request)
        do {
            headers["Cache-Control"] = "public, max-age=\(statsCacheSeconds)"
            let response = try await stats.handle()
            return .json(response, statusCode: .ok, headers: headers)
        } catch {
            // The one handler that propagates store failures (`StatsHandler`). The detail goes
            // to the log — the error came from the table, not the caller, and the caller can do
            // nothing with it but refresh.
            logger.error("Stats read failed", metadata: ["error": "\(error)"])
            return .error(
                statusCode: .internalServerError,
                message: "Stats are unavailable",
                headers: headers)
        }
    }

    // MARK: - Helpers

    /// CORS headers for a request whose `Origin` header is in the allowlist.
    /// Returns an empty dict when CORS is disabled or the origin is not allowed —
    /// callers merge this into their own response headers.
    private func corsHeaders(for request: Routing.HTTPRequest) -> [String: String] {
        guard let matched = corsConfig.match(request.headers["origin"]) else { return [:] }
        return [
            "Access-Control-Allow-Origin": matched,
            "Vary": "Origin",
        ]
    }

    /// The wire form of a handler error: `ErrorResponse` under the error's own status code.
    private static func response(
        for error: KeelError,
        headers: [String: String] = [:]
    ) -> RouteResponse {
        .json(ErrorResponse(error), statusCode: .init(code: error.statusCode), headers: headers)
    }
}

extension HTTPRouterBuilder {
    /// Add the Keel endpoints to this builder, beside whatever routes the app registers itself.
    public func mount(keel: KeelRouter) {
        keel.register(on: self)
    }
}

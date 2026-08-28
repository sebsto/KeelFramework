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
/// `Cache-Control` each response carries, and how a `KeelError` becomes a status code.
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

    let logger: Logger

    public init(
        bootstrap: BootstrapHandler,
        ping: PingHandler,
        stats: StatsHandler,
        aliases: AliasRoutes = .none,
        bootstrapCacheSeconds: Int = 60,
        statsCacheSeconds: Int = 300,
        logger: Logger = Logger(label: "keel.router")
    ) {
        self.bootstrap = bootstrap
        self.ping = ping
        self.stats = stats
        self.aliases = aliases
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

    // MARK: - Edge adapters

    private func handleBootstrap(
        _ request: Routing.HTTPRequest, envelope: AliasRoutes.Envelope
    ) async throws -> RouteResponse {
        let response = await bootstrap.handle(
            BootstrapHandler.Request(query: request.event.queryStringParameters))
        let headers = ["Cache-Control": "public, max-age=\(bootstrapCacheSeconds)"]
        switch envelope {
        case .standard:
            return .json(response, statusCode: .ok, headers: headers)
        case .flattened:
            return .json(try response.flattened(), statusCode: .ok, headers: headers)
        }
    }

    private func handlePing(_ request: Routing.HTTPRequest) async -> RouteResponse {
        let body: PingRequest
        do {
            body = try WireJSON.decoder().decode(PingRequest.self, from: request.body)
        } catch {
            // The decode error's own description can quote the body, and `docs/PRIVACY.md`
            // promises request bodies are never echoed or logged — so the client gets the
            // field-free version and the log gets nothing.
            return Self.response(
                for: .badRequest(field: "body", reason: "not a valid ping request"))
        }
        do {
            return .json(try await ping.handle(body), statusCode: .ok)
        } catch {
            return Self.response(for: error)
        }
    }

    private func handleStats(_ request: Routing.HTTPRequest) async -> RouteResponse {
        do {
            let response = try await stats.handle()
            return .json(
                response,
                statusCode: .ok,
                headers: ["Cache-Control": "public, max-age=\(statsCacheSeconds)"])
        } catch {
            // The one handler that propagates store failures (`StatsHandler`). The detail goes
            // to the log — the error came from the table, not the caller, and the caller can do
            // nothing with it but refresh.
            logger.error("Stats read failed", metadata: ["error": "\(error)"])
            return .error(statusCode: .internalServerError, message: "Stats are unavailable")
        }
    }

    /// The wire form of a handler error: `ErrorResponse` under the error's own status code.
    private static func response(for error: KeelError) -> RouteResponse {
        .json(ErrorResponse(error), statusCode: .init(code: error.statusCode))
    }
}

extension HTTPRouterBuilder {
    /// Add the Keel endpoints to this builder, beside whatever routes the app registers itself.
    public func mount(keel: KeelRouter) {
        keel.register(on: self)
    }
}

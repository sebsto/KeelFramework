#if canImport(FoundationEssentials)
public import FoundationEssentials
#else
public import Foundation
#endif

/// The Keel backend, as the app talks to it: bootstrap, ping, stats.
///
/// Grace-first is the design rule (`docs/ARCHITECTURE.md` §1), and it is enforced here
/// rather than promised: every call races `Keel.requestTimeout`, whatever the transport —
/// the budget binds fakes and future adapters exactly as it binds `URLSession`.
///
/// The error policy differs per call because the callers differ:
/// - `bootstrap()` **throws**, because its caller is `RemoteConfigStore`, which owns the
///   cache-fallback decision and needs to know the network copy did not arrive.
/// - `send(ping:)` **returns a Bool**, because telemetry must never surface an error into
///   a launch path; the one caller need is the `firstPaidLaunch` ratchet, which must latch
///   only on a ping the server actually took.
/// - `stats()` **throws** — it is a dashboard call, and a partial answer helps nobody.
public struct BackendClient: Sendable {
    public let baseURL: URL
    let authorization: KeelAuthorization
    let transport: any HTTPTransport

    public init(
        baseURL: URL,
        authorization: KeelAuthorization = .none,
        transport: any HTTPTransport = URLSessionTransport()
    ) {
        self.baseURL = baseURL
        self.authorization = authorization
        self.transport = transport
    }

    // MARK: - Calls

    /// `GET /v1/bootstrap`, decoded for this app's payload type.
    ///
    /// The query carries what the server's gate reasons about. `os` and `locale` are sent
    /// too — the contract reserves them, and sending them now means a future server-side
    /// narrowing needs no client release.
    public func bootstrap<App: Decodable & Sendable>(
        appVersion: String,
        platform: Platform,
        osVersion: String? = nil,
        locale: String? = nil,
        as appType: App.Type = App.self
    ) async throws(KeelClientError) -> BootstrapResponse<App> {
        try await bootstrapWithBody(
            appVersion: appVersion, platform: platform, osVersion: osVersion, locale: locale
        ).response
    }

    /// `bootstrap`, also returning the verbatim response bytes.
    ///
    /// The bytes exist for one caller: `RemoteConfigStore`'s disk cache persists what the
    /// server *sent*, not a re-encoding — `BootstrapResponse` is deliberately
    /// `Decodable`-only on this side, and a cache of wire bytes survives an app-payload
    /// type change by failing its decode instead of failing to be written.
    public func bootstrapWithBody<App: Decodable & Sendable>(
        appVersion: String,
        platform: Platform,
        osVersion: String? = nil,
        locale: String? = nil,
        as appType: App.Type = App.self
    ) async throws(KeelClientError) -> (response: BootstrapResponse<App>, body: Data) {
        var query = [("appVersion", appVersion), ("platform", platform.rawValue)]
        if let osVersion { query.append(("os", osVersion)) }
        if let locale { query.append(("locale", locale)) }

        let (response, body): (BootstrapResponse<App>, Data) = try await get(
            path: Keel.Route.bootstrap.rawValue, query: query)
        guard response.schemaVersion >= Keel.schemaVersion else {
            // Older means a rollback past a field this build requires. Newer is fine —
            // unknown fields were already ignored by the decode that just succeeded.
            throw .unsupportedSchema(serverVersion: response.schemaVersion)
        }
        return (response, body)
    }

    /// `POST /v1/ping`. Returns whether the server accepted it; never throws.
    ///
    /// Discardable because only the `firstPaidLaunch` ratchet cares: a conversion is once
    /// per install, so `TelemetryService` latches its sticky flag only on `true` — a
    /// dropped conversion ping is lost forever, unlike a daily boolean that re-fires
    /// tomorrow.
    @discardableResult
    public func send(ping: PingRequest) async -> Bool {
        guard !ping.isNoOp else { return true }
        do {
            let body = try WireJSON.encoder().encode(ping)
            let response = try await withBudget {
                var request = HTTPRequestData(
                    method: .post,
                    url: url(path: Keel.Route.ping.rawValue, query: []),
                    headers: ["Content-Type": "application/json"],
                    body: body)
                if let header = await authorization.headerValue() {
                    request.headers["Authorization"] = header
                }
                return try await transport.send(request)
            }
            return (200..<300).contains(response.statusCode)
        } catch {
            return false
        }
    }

    /// `GET /v1/stats` — the published aggregates, for an in-app stats screen.
    public func stats() async throws(KeelClientError) -> StatsResponse {
        try await get(path: Keel.Route.stats.rawValue, query: []).0
    }

    /// `POST /v1/purchase` — report a StoreKit transaction to a backend with IAP mounted.
    ///
    /// Throws, unlike the ping: the caller is a purchase flow, and it must know whether
    /// the server recorded the entitlement before it tells the user everything worked.
    public func purchase(
        userId: String, jws: String
    ) async throws(KeelClientError) -> EntitlementResponse {
        let body: Data
        do {
            body = try WireJSON.encoder().encode(PurchaseRequest(userId: userId, jws: jws))
        } catch {
            throw .malformedResponse
        }
        let response: HTTPResponseData
        do {
            response = try await withBudget {
                var request = HTTPRequestData(
                    method: .post,
                    url: url(path: "/v1/purchase", query: []),
                    headers: ["Content-Type": "application/json"],
                    body: body)
                if let header = await authorization.headerValue() {
                    request.headers["Authorization"] = header
                }
                return try await transport.send(request)
            }
        } catch let error as KeelClientError {
            throw error
        } catch {
            throw .notHTTP
        }
        guard (200..<300).contains(response.statusCode) else {
            let details = try? WireJSON.decoder().decode(ErrorResponse.self, from: response.body)
            throw .serverError(statusCode: response.statusCode, code: details?.code)
        }
        guard
            let decoded = try? WireJSON.decoder().decode(
                EntitlementResponse.self, from: response.body)
        else {
            throw .malformedResponse
        }
        return decoded
    }

    /// `GET /v1/entitlement` — what the server holds for one user.
    public func entitlements(
        userId: String
    ) async throws(KeelClientError) -> EntitlementResponse {
        try await get(path: "/v1/entitlement", query: [("userId", userId)]).0
    }

    // MARK: - Plumbing

    private func get<Response: Decodable & Sendable>(
        path: String, query: [(String, String)]
    ) async throws(KeelClientError) -> (Response, Data) {
        let response: HTTPResponseData
        do {
            response = try await withBudget {
                var request = HTTPRequestData(method: .get, url: url(path: path, query: query))
                if let header = await authorization.headerValue() {
                    request.headers["Authorization"] = header
                }
                return try await transport.send(request)
            }
        } catch let error as KeelClientError {
            throw error
        } catch {
            throw .notHTTP
        }

        guard (200..<300).contains(response.statusCode) else {
            let details = try? WireJSON.decoder().decode(ErrorResponse.self, from: response.body)
            throw .serverError(statusCode: response.statusCode, code: details?.code)
        }
        guard let decoded = try? WireJSON.decoder().decode(Response.self, from: response.body)
        else {
            throw .malformedResponse
        }
        return (decoded, response.body)
    }

    private func url(path: String, query: [(String, String)]) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let basePath = components?.path ?? ""
        components?.path = basePath.hasSuffix("/") ? basePath + path.dropFirst() : basePath + path
        if !query.isEmpty {
            components?.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        }
        // A base URL bad enough to defeat URLComponents is a compile-time constant typo;
        // falling back to the base keeps this total and the request then fails visibly.
        return components?.url ?? baseURL
    }

    /// Race `operation` against `Keel.requestTimeout`; the loser is cancelled.
    private func withBudget(
        _ operation: @escaping @Sendable () async throws -> HTTPResponseData
    ) async throws -> HTTPResponseData {
        try await withThrowingTaskGroup(of: HTTPResponseData.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: Keel.requestTimeout)
                throw KeelClientError.timedOut
            }
            guard let first = try await group.next() else {
                throw KeelClientError.timedOut
            }
            group.cancelAll()
            return first
        }
    }
}

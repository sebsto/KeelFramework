import Foundation
import Testing

@testable import KeelCore

/// A canned transport: responses by path, requests recorded. An actor-free `final class`
/// with locking would need `Synchronization`, which Skip-safe test code avoids; the test
/// target is Apple/Linux only, so an actor with async accessors is the simpler tool.
actor FakeTransport: HTTPTransport {
    enum Behavior {
        case respond(HTTPResponseData)
        case hang
    }

    private var behaviors: [String: Behavior] = [:]
    private(set) var requests: [HTTPRequestData] = []

    func respond(to path: String, status: Int = 200, body: String) {
        behaviors[path] = .respond(HTTPResponseData(statusCode: status, body: Data(body.utf8)))
    }

    func hang(on path: String) {
        behaviors[path] = .hang
    }

    func send(_ request: HTTPRequestData) async throws -> HTTPResponseData {
        requests.append(request)
        switch behaviors[request.url.path] {
        case .respond(let response):
            return response
        case .hang:
            // Far past any budget; cancellation is what ends it.
            try await Task.sleep(for: .seconds(3_600))
            throw KeelClientError.timedOut
        case nil:
            return HTTPResponseData(statusCode: 404, body: Data())
        }
    }
}

@Suite("Backend client")
struct BackendClientTests {

    static let base = URL(string: "https://api.example.com")!

    private static func client(
        _ transport: FakeTransport, authorization: KeelAuthorization = .none
    ) -> BackendClient {
        BackendClient(baseURL: Self.base, authorization: authorization, transport: transport)
    }

    private static let bootstrapBody = """
        {"schemaVersion": 1, "generatedAt": "2026-08-24T10:00:00Z",
         "features": {"sleep_timer": true},
         "telemetry": {"enabled": true},
         "app": {"streamURL": "https://audio.example.com/x"}}
        """

    // MARK: - Bootstrap

    @Test("Bootstrap sends the documented query and decodes the app payload")
    func bootstrapRoundTrip() async throws {
        let transport = FakeTransport()
        await transport.respond(to: "/v1/bootstrap", body: Self.bootstrapBody)

        struct AppConfig: Decodable, Sendable, Equatable {
            var streamURL: String
        }
        let response: BootstrapResponse<AppConfig> = try await Self.client(transport)
            .bootstrap(appVersion: "2.1.0", platform: .iOS, osVersion: "26.1")

        #expect(response.features == ["sleep_timer": true])
        #expect(response.app == AppConfig(streamURL: "https://audio.example.com/x"))

        let request = try #require(await transport.requests.first)
        #expect(request.method == .get)
        let components = try #require(
            URLComponents(url: request.url, resolvingAgainstBaseURL: false))
        let query = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })
        #expect(query["appVersion"] == "2.1.0")
        #expect(query["platform"] == "ios")
        #expect(query["os"] == "26.1")
    }

    @Test("A schema older than this build is refused")
    func rejectsOlderSchema() async throws {
        let transport = FakeTransport()
        await transport.respond(
            to: "/v1/bootstrap",
            body: #"{"schemaVersion": 0, "generatedAt": "2026-08-24T10:00:00Z"}"#)

        // Older means a server rolled back past a field this build requires; serving a
        // half-understood config is worse than falling back to the cached one.
        await #expect(throws: KeelClientError.unsupportedSchema(serverVersion: 0)) {
            let _: BootstrapResponse<Empty> = try await Self.client(transport)
                .bootstrap(appVersion: "1.0", platform: .iOS)
        }
    }

    @Test("A schema newer than this build is fine — unknown fields were already ignored")
    func toleratesNewerSchema() async throws {
        let transport = FakeTransport()
        await transport.respond(
            to: "/v1/bootstrap",
            body: #"{"schemaVersion": 9, "generatedAt": "2026-08-24T10:00:00Z", "novel": {}}"#)
        let response: BootstrapResponse<Empty> = try await Self.client(transport)
            .bootstrap(appVersion: "1.0", platform: .iOS)
        #expect(response.schemaVersion == 9)
    }

    @Test("A server error carries the status and the machine-readable code")
    func serverErrorDetails() async {
        let transport = FakeTransport()
        await transport.respond(
            to: "/v1/bootstrap",
            status: 400,
            body: #"{"error": "appVersion: must not be empty", "code": "validation_error"}"#)

        await #expect(
            throws: KeelClientError.serverError(statusCode: 400, code: "validation_error")
        ) {
            let _: BootstrapResponse<Empty> = try await Self.client(transport)
                .bootstrap(appVersion: "1.0", platform: .iOS)
        }
    }

    @Test("Unparseable success bodies are malformedResponse, not a crash or a hang")
    func malformedBody() async {
        let transport = FakeTransport()
        await transport.respond(to: "/v1/bootstrap", body: "not json")
        await #expect(throws: KeelClientError.malformedResponse) {
            let _: BootstrapResponse<Empty> = try await Self.client(transport)
                .bootstrap(appVersion: "1.0", platform: .iOS)
        }
    }

    @Test("The three-second budget binds, even against a transport that never answers")
    func budgetBinds() async {
        let transport = FakeTransport()
        await transport.hang(on: "/v1/bootstrap")

        let started = ContinuousClock.now
        await #expect(throws: KeelClientError.timedOut) {
            let _: BootstrapResponse<Empty> = try await Self.client(transport)
                .bootstrap(appVersion: "1.0", platform: .iOS)
        }
        let elapsed = ContinuousClock.now - started
        // Enforced by the client, not the socket: nothing Keel does may keep a launch
        // waiting longer than the budget, whatever the transport is doing.
        #expect(elapsed < .seconds(10))
    }

    // MARK: - Authorization

    @Test("Bearer authorization rides every request")
    func bearerHeader() async throws {
        let transport = FakeTransport()
        await transport.respond(to: "/v1/ping", body: #"{"ok": true}"#)

        let client = Self.client(transport, authorization: .bearer { "s3cret" })
        await client.send(ping: Self.ping())

        let request = try #require(await transport.requests.first)
        #expect(request.headers["Authorization"] == "Bearer s3cret")
    }

    // MARK: - Ping

    private static func ping(
        firstToday: Bool = true
    ) -> PingRequest {
        PingRequest(
            firstPingEver: false,
            firstToday: firstToday,
            firstThisMonth: false,
            firstThisVersion: false,
            firstPaidLaunch: false,
            appVersion: "2.1.0",
            osVersion: "26.1",
            platform: .iOS,
            licenseState: .free)
    }

    @Test("An accepted ping reports true; the paid ratchet depends on this")
    func acceptedPing() async {
        let transport = FakeTransport()
        await transport.respond(to: "/v1/ping", body: #"{"ok": true}"#)
        #expect(await Self.client(transport).send(ping: Self.ping()))
    }

    @Test("A rejected or unreachable ping reports false and throws nothing")
    func failedPing() async {
        let rejecting = FakeTransport()
        await rejecting.respond(to: "/v1/ping", status: 400, body: "{}")
        #expect(await !Self.client(rejecting).send(ping: Self.ping()))

        let hanging = FakeTransport()
        await hanging.hang(on: "/v1/ping")
        #expect(await !Self.client(hanging).send(ping: Self.ping()))
    }

    @Test("A no-op ping is not sent at all")
    func noOpPingCostsNothing() async {
        let transport = FakeTransport()
        let accepted = await Self.client(transport).send(ping: Self.ping(firstToday: false))
        // True, not false: nothing needed saying and nothing was lost.
        #expect(accepted)
        #expect(await transport.requests.isEmpty)
    }

    // MARK: - IAM / signing transport

    @Test("An app-owned signing transport receives every request with .none authorization")
    func customSigningTransportReceivesRequests() async throws {
        // Demonstrates the contract for the SigV4 path documented in docs/INTEGRATION.md
        // §IAM-transport-contract: BackendClient with .none authorization passes the raw
        // HTTPRequestData to the transport unchanged; the transport (not the client) is
        // responsible for adding AWS4-HMAC-SHA256 Authorization, x-amz-content-sha256, and
        // x-amz-security-token before sending over the wire.
        //
        // This mirrors how an app wires KeelSigV4Transport: it injects the transport at
        // BackendClient init, sets .none as the authorization mode (no Bearer header needed),
        // and the transport handles signing.
        actor SigningRecorder: HTTPTransport {
            private let base: FakeTransport
            private(set) var didSign = false

            init(_ base: FakeTransport) { self.base = base }

            func send(_ request: HTTPRequestData) async throws -> HTTPResponseData {
                // A real SigV4 transport adds Authorization / x-amz-* here.
                // This stub just records that the hook fired.
                didSign = true
                return try await base.send(request)
            }
        }

        let fake = FakeTransport()
        await fake.respond(to: "/v1/ping", body: #"{"ok":true}"#)

        let recorder = SigningRecorder(fake)
        // .none: no Bearer header — the transport owns all authorization.
        let client = BackendClient(
            baseURL: Self.base, authorization: .none, transport: recorder)
        await client.send(ping: Self.ping())

        // The transport's signing hook was called, confirming BackendClient delegates
        // every outgoing request to the injected transport without modification.
        #expect(await recorder.didSign)
        // No Authorization header was prepended by the client itself.
        let request = try #require(await fake.requests.first)
        #expect(request.headers["Authorization"] == nil)
    }

    // MARK: - Stats

    @Test("Stats decodes the published aggregates")
    func stats() async throws {
        let transport = FakeTransport()
        await transport.respond(
            to: "/v1/stats",
            body: """
                {"generatedAt": "2026-08-24T10:00:00Z", "installs": 12043, "conversions": 388,
                 "dau": [], "dauByState": [], "mau": [], "mauByState": [],
                 "versions": [], "osVersions": [], "platforms": [], "dimensions": {}}
                """)
        let response = try await Self.client(transport).stats()
        #expect(response.installs == 12_043)
        #expect(response.conversions == 388)
    }
}

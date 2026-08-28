import Foundation
public import KeelCore

/// A canned `HTTPTransport`: responses by path, requests recorded, optional hangs for
/// exercising the 3-second budget.
///
/// An actor, so it is `Sendable` without this package importing `Synchronization`; the
/// `await` on assertions is the cost, and it is small.
public actor FakeTransport: HTTPTransport {
    enum Behavior {
        case respond(HTTPResponseData)
        case hang
    }

    private var behaviors: [String: Behavior] = [:]

    /// Every request received, in order. Assert on method, URL query, headers, body.
    public private(set) var requests: [HTTPRequestData] = []

    public init() {}

    /// Serve `body` with `status` for any request whose URL path is `path`.
    public func respond(to path: String, status: Int = 200, body: String) {
        behaviors[path] = .respond(
            HTTPResponseData(statusCode: status, body: Data(body.utf8)))
    }

    /// Never answer requests to `path` — the caller's timeout is what ends them.
    public func hang(on path: String) {
        behaviors[path] = .hang
    }

    public func send(_ request: HTTPRequestData) async throws -> HTTPResponseData {
        requests.append(request)
        switch behaviors[request.url.path] {
        case .respond(let response):
            return response
        case .hang:
            try await Task.sleep(for: .seconds(3_600))
            throw KeelClientError.timedOut
        case nil:
            // An unconfigured path is a test bug; 404 makes it visible as a failed
            // assertion rather than a decode error three lines later.
            return HTTPResponseData(statusCode: 404, body: Data())
        }
    }
}

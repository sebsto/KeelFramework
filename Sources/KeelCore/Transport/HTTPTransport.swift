#if canImport(FoundationEssentials)
public import FoundationEssentials
#else
public import Foundation
#endif

#if canImport(FoundationNetworking)
public import FoundationNetworking
#endif

/// One HTTP request, as `BackendClient` describes it to a transport.
///
/// A struct rather than `URLRequest` so a fake transport needs no Foundation networking at
/// all, and so the request a test asserts on is exactly the request the client built.
public struct HTTPRequestData: Sendable, Equatable {
    public enum Method: String, Sendable {
        case get = "GET"
        case post = "POST"
    }

    public var method: Method
    public var url: URL
    public var headers: [String: String]
    public var body: Data?

    public init(method: Method, url: URL, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public struct HTTPResponseData: Sendable, Equatable {
    public var statusCode: Int
    public var body: Data

    public init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }
}

/// The one effect `KeelCore` performs. Everything above it is a pure function of the
/// response, which is what lets the whole client be tested with a dictionary of canned
/// responses and no network.
public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequestData) async throws -> HTTPResponseData
}

/// The production transport: one `URLSession` call.
public struct URLSessionTransport: HTTPTransport {
    let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: HTTPRequestData) async throws -> HTTPResponseData {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        let (data, response) = try await session.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw KeelClientError.notHTTP
        }
        return HTTPResponseData(statusCode: httpResponse.statusCode, body: data)
    }
}

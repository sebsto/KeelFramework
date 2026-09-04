public import KeelCore

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// MARK: - Recording transport (available on all platforms)

/// A test double for an app-owned SigV4 (or any signing) transport.
///
/// Wraps a `FakeTransport` and records every request that passes through `send(_:)`.
/// Available on all platforms (no CryptoKit required). Use this in tests that only need
/// to verify the `BackendClient` → transport wiring, not the signature value itself.
///
/// For a real signature assertion use `KeelSigV4Transport` from the `KeelClientSigning`
/// production module (Apple/CryptoKit-gated).
///
/// ### Typical usage
///
/// ```swift
/// let recording = RecordingSigningTransport(wrapping: FakeTransport())
/// await recording.inner.respond(to: "/v1/ping", body: #"{"ok":true}"#)
///
/// let client = BackendClient(
///     baseURL: URL(string: "https://api.example.com")!,
///     authorization: .none,
///     transport: recording)
/// await client.send(ping: myPing)
///
/// let requests = await recording.requests
/// #expect(!requests.isEmpty)
/// #expect(requests.first?.headers["authorization"] == nil)  // client adds no auth header
/// ```
public actor RecordingSigningTransport: HTTPTransport {
    /// The underlying fake that supplies canned responses.
    public let inner: FakeTransport

    /// Every request received by `send(_:)`, in order.
    public private(set) var requests: [HTTPRequestData] = []

    /// Back-compat alias: same as `requests`. Deprecated — use `requests` directly.
    @available(*, deprecated, renamed: "requests")
    public var signed: [HTTPRequestData] { requests }

    public init(wrapping inner: FakeTransport = FakeTransport()) {
        self.inner = inner
    }

    public func send(_ request: HTTPRequestData) async throws -> HTTPResponseData {
        requests.append(request)
        return try await inner.send(request)
    }
}

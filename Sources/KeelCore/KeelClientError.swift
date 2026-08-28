/// What can go wrong between the app and its backend, as the client reports it.
///
/// Small and closed on purpose. Callers rarely branch on more than "did it work" — the
/// framework's own policy is grace-first, so most of these are logged and absorbed rather
/// than shown — but when a log line exists it should say which of these five it was.
public enum KeelClientError: Error, Sendable, Equatable {
    /// The request did not complete within `Keel.requestTimeout`. The budget binds every
    /// transport, fakes included, because it is enforced by the client, not the socket.
    case timedOut

    /// Non-2xx status. The body may carry an `ErrorResponse`; `code` is its machine half
    /// when it decoded, so a caller can branch without parsing prose.
    case serverError(statusCode: Int, code: String?)

    /// A 2xx whose body did not decode as the expected type.
    case malformedResponse

    /// The response's `schemaVersion` is *older* than this build requires — a server
    /// rolled back past a field the client depends on. Newer is fine and expected;
    /// unknown fields are ignored.
    case unsupportedSchema(serverVersion: Int)

    /// The transport returned something that was not an HTTP response at all.
    case notHTTP
}

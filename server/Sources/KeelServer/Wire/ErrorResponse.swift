/// The body of every non-2xx Keel response: `{"error": "...", "code": "..."}`.
///
/// `error` is the human-readable half and matches the `{"error": …}` shape lambda-kit's own
/// fallbacks emit, so a client sees one error shape no matter which layer produced it. `code` is
/// the machine-readable half — a client branches on it without parsing prose (`KeelError.code`).
public struct ErrorResponse: Encodable, Sendable, Equatable {
    public var error: String
    public var code: String

    public init(error: String, code: String) {
        self.error = error
        self.code = code
    }

    /// The wire form of a handler error.
    public init(_ keelError: KeelError) {
        self.init(error: keelError.message, code: keelError.code)
    }
}

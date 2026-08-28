/// The errors a Keel handler raises, and the only ones a transport has to map to a status code.
///
/// Deliberately small and closed, so the handlers can use typed `throws` and the Lambda layer's
/// mapping is exhaustive at compile time rather than a `default: 500`.
///
/// Store failures are *not* in here. A handler either swallows them (`PingHandler`, where a lost
/// count is better than a failed request), absorbs them (`BootstrapHandler`, which serves stale
/// or default config), or lets them propagate untyped (`StatsHandler`). Wrapping an open error
/// set into a closed one would mean inventing a case whose payload is a string nobody can act on.
public enum KeelError: Error, Sendable, Equatable {
    /// The request is malformed or violates a documented limit. The message is safe to return to
    /// the caller: it names the field and the rule, never the value that broke it, because the
    /// value came from a request body and `docs/PRIVACY.md` promises those are not echoed.
    case badRequest(field: String, reason: String)

    /// No route matched. Carries the normalised path for the log, not for the response body.
    case notFound(path: String)

    /// The path exists but not with this method — `GET /v1/ping` rather than a typo.
    case methodNotAllowed(method: String, path: String)

    /// The HTTP status a transport should return.
    public var statusCode: Int {
        switch self {
        case .badRequest: 400
        case .notFound: 404
        case .methodNotAllowed: 405
        }
    }

    /// A stable machine-readable code, so a client can branch without parsing prose.
    public var code: String {
        switch self {
        case .badRequest: "validation_error"
        case .notFound: "not_found"
        case .methodNotAllowed: "method_not_allowed"
        }
    }

    /// What the caller is told. Terse on purpose — a validation message is a developer aid, and
    /// the developer has the field name and the rule, which is everything actionable.
    public var message: String {
        switch self {
        case .badRequest(let field, let reason): "\(field): \(reason)"
        case .notFound(let path): "No route for \(path)"
        case .methodNotAllowed(let method, let path): "\(method) is not allowed on \(path)"
        }
    }
}

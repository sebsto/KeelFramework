/// How requests to the backend are authorized — the client's half of the CDK's `KeelAuth`.
///
/// `iam` mode has no case here: SigV4 signing needs a credentials provider and belongs to
/// the app's own transport (odvpn signs with Cognito credentials in a custom
/// `HTTPTransport`), not to a framework that ships no AWS dependency.
public enum KeelAuthorization: Sendable {
    /// No header. For `KeelAuth.none()` backends and for public routes.
    case none

    /// `Authorization: Bearer <token>`, the shape both the shared-secret authorizer and a
    /// JWT authorizer read. A closure rather than a stored string so a JWT can be refreshed
    /// per request; a fixed shared secret is `.bearer { secret }`.
    case bearer(@Sendable () async -> String)

    /// The header for one request, or nil for none.
    func headerValue() async -> String? {
        switch self {
        case .none: nil
        case .bearer(let token): "Bearer \(await token())"
        }
    }
}

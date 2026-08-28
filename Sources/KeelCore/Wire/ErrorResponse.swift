/// The body of a non-2xx Keel response: `{"error": "...", "code": "..."}`.
///
/// `Decodable` only — the client reads these and never writes one. Both fields are
/// defaulted on decode, because a gateway-generated error (`{"message": "Forbidden"}`, say)
/// is not this shape and still should not turn a 403 into a decoding crash.
public struct ErrorResponse: Decodable, Sendable, Equatable {
    /// The human-readable half. Names the field and the rule, never an echoed value.
    public var error: String

    /// The machine-readable half — `validation_error`, `not_found`, … — for branching
    /// without parsing prose.
    public var code: String

    public init(error: String, code: String) {
        self.error = error
        self.code = code
    }

    enum CodingKeys: String, CodingKey {
        case error, code
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        error = try container.decodeIfPresent(String.self, forKey: .error) ?? ""
        code = try container.decodeIfPresent(String.self, forKey: .code) ?? ""
    }
}

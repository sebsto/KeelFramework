/// Arbitrary JSON, carried through the server without being understood.
///
/// The `app` section of the bootstrap response is the app's own business: a station list, a
/// region list, whatever the app needs. The framework stores it, ages it in a cache, and hands
/// it back byte-for-byte — it must never require a Swift type on this side, because that would
/// make "add a field to my config" a framework release.
///
/// Also what `keel config set` writes and what `ConfigStore` round-trips.
///
/// `Int` and `Double` are separate cases so that a value written as `3` comes back as `3` rather
/// than `3.0` — otherwise every `keel config set` read-modify-write would rewrite the app's own
/// numbers.
///
/// The normalisation is one-way, and deliberately: `3.0` decodes to `.int(3)`, because
/// `JSONDecoder` accepts a fraction-free number as an `Int` and there is no way to see the
/// original spelling from inside `Decodable`. JSON has a single number type, so `3.0` and `3` are
/// the same value and rendering it the shorter way loses nothing. `3.5` stays a `.double`.
public enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            // Before Double, so integral values keep their exact form.
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Not a JSON value.")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    // MARK: - Reading

    /// The object's members, or nil if this is not an object. Named rather than subscripted so
    /// that `config.app?.object?["theme"]` reads as the chain of maybes it is.
    public var object: [String: JSONValue]? {
        guard case .object(let members) = self else { return nil }
        return members
    }

    public var array: [JSONValue]? {
        guard case .array(let elements) = self else { return nil }
        return elements
    }

    public var string: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    public var bool: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    /// An `Int` from either numeric case, exact only. `3.0` reads as `3`; `3.5` reads as nil
    /// rather than truncating, because a config value quietly losing its fraction is worse
    /// than a value the app reports as missing.
    public var int: Int? {
        switch self {
        case .int(let value): return value
        case .double(let value):
            guard value.rounded() == value, value >= -9_007_199_254_740_992,
                value <= 9_007_199_254_740_992
            else { return nil }
            return Int(value)
        default: return nil
        }
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// Member lookup on an object, nil for anything else. Not `ExpressibleByNilLiteral`
    /// gymnastics — just enough to read a config without a switch at every level.
    public subscript(key: String) -> JSONValue? {
        object?[key]
    }
}

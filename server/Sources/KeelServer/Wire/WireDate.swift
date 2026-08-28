#if canImport(FoundationEssentials)
public import FoundationEssentials
#else
public import Foundation
#endif

/// ISO 8601 date coding, done per-property inside `init(from:)` rather than by configuring the
/// coder with `dateDecodingStrategy`.
///
/// Three reasons it works this way:
/// - A coder-level strategy is invisible at the call site. Someone who reaches for a plain
///   `JSONDecoder()` to decode a `BootstrapResponse` gets a confusing failure about a Double
///   instead of a date; doing it in the type means the type is correct with *any* decoder.
/// - `.custom` strategies take a closure the transpiler has to reproduce, and the client copy
///   of these types has to survive Skip.
/// - `Date`'s own `Codable` conformance encodes a Double, which is the one format we must never
///   emit — timestamps on the wire are human-readable or they are not debuggable.
///
/// The format is exactly what `UTCDate.iso8601String(_:)` writes and what
/// `UTCDate.date(fromISO8601:)` accepts: second precision, UTC, `Z`-suffixed on the way out,
/// tolerant of offsets and fractional seconds on the way in.
extension KeyedDecodingContainer {
    /// Decodes a required ISO 8601 timestamp.
    public func decodeISO8601(forKey key: Key) throws -> Date {
        let string = try decode(String.self, forKey: key)
        guard let date = UTCDate.date(fromISO8601: string) else {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: self,
                debugDescription: "Expected an ISO 8601 timestamp, found \"\(string)\".")
        }
        return date
    }

    /// Decodes an optional ISO 8601 timestamp.
    ///
    /// An explicit `null` and an absent key both yield nil, matching every other optional on
    /// these types — a server that writes `"until": null` to mean "unknown" is not wrong.
    /// A *present but malformed* string still throws, because that is a bug rather than an
    /// absence.
    public func decodeISO8601IfPresent(forKey key: Key) throws -> Date? {
        guard let string = try decodeIfPresent(String.self, forKey: key) else { return nil }
        guard let date = UTCDate.date(fromISO8601: string) else {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: self,
                debugDescription: "Expected an ISO 8601 timestamp, found \"\(string)\".")
        }
        return date
    }
}

extension KeyedEncodingContainer {
    /// Encodes an ISO 8601 timestamp: `2026-08-24T10:00:00Z`.
    public mutating func encodeISO8601(_ date: Date, forKey key: Key) throws {
        try encode(UTCDate.iso8601String(date), forKey: key)
    }

    /// Encodes an ISO 8601 timestamp, omitting the key entirely when nil.
    ///
    /// Omission rather than `null`: an absent section means "no opinion" throughout this
    /// contract, and writing nulls would make every fixture carry keys that say nothing.
    public mutating func encodeISO8601IfPresent(_ date: Date?, forKey key: Key) throws {
        guard let date else { return }
        try encodeISO8601(date, forKey: key)
    }
}

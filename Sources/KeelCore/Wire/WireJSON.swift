#if canImport(FoundationEssentials)
public import FoundationEssentials
#else
public import Foundation
#endif

/// The JSON coders used for every Keel request and response, on both sides of the wire.
///
/// The wire types carry their own date handling (see `WireDate.swift`), so these coders need no
/// strategy configuration — which is the point. Anyone who decodes a `BootstrapResponse` with a
/// plain `JSONDecoder()` gets the same result; using `WireJSON` only buys the output formatting
/// and keeps one place to change if the contract ever needs a coder-level setting.
///
/// `KeelServer` declares an identical copy, pinned to this one by the golden fixtures.
public enum WireJSON {
    /// A fresh encoder.
    ///
    /// A function rather than a shared `static let`: `JSONEncoder` is a non-`Sendable` class,
    /// and one shared instance mutated from two concurrent Lambda invocations is exactly the
    /// data race strict concurrency exists to reject. They are cheap to create — cheaper than
    /// the request that follows.
    ///
    /// - `sortedKeys` makes the bytes deterministic, which is what lets the golden fixtures be
    ///   compared as bytes instead of re-parsed and compared field by field.
    /// - `withoutEscapingSlashes` keeps the URLs in `urls` readable; `https:\/\/…` is valid
    ///   JSON but nobody wants to read it in a fixture or a log.
    /// - `prettyPrinted` is for fixtures and `keel stats dump`, never for a response — 300 kB
    ///   of indentation on a stats payload is bandwidth spent on whitespace.
    public static func encoder(pretty: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting =
            pretty
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// A fresh decoder. Non-`Sendable` for the same reason as the encoder.
    ///
    /// Left at its defaults deliberately: unknown keys are ignored, which is what makes a
    /// client tolerate a server that has learned new fields, and every wire type's
    /// `init(from:)` already defaults the sections that may be absent.
    public static func decoder() -> JSONDecoder {
        JSONDecoder()
    }
}

#if canImport(FoundationEssentials)
public import FoundationEssentials
#else
public import Foundation
#endif

/// The single base64url codec for KeelIAP: URL-safe alphabet with padding stripped on
/// encode and tolerated on decode. JWS segments are base64url; `Foundation` only speaks
/// plain base64.
public enum Base64URL {
    /// Encodes `data` as base64url without padding.
    ///
    /// Character mapping by hand rather than `replacingOccurrences`, which lives outside
    /// `FoundationEssentials` on Linux.
    public static func encode(_ data: Data) -> String {
        String(
            data.base64EncodedString().compactMap { character in
                switch character {
                case "+": "-"
                case "/": "_"
                case "=": nil
                default: character
                }
            })
    }

    /// Decodes a base64url string (tolerating missing padding), or nil when not valid
    /// base64.
    public static func decode(_ string: String) -> Data? {
        var base64 = String(
            string.map { character in
                switch character {
                case "-": "+"
                case "_": "/"
                default: character
                }
            })
        let remainder = base64.count % 4
        if remainder > 0 { base64.append(String(repeating: "=", count: 4 - remainder)) }
        return Data(base64Encoded: base64)
    }
}

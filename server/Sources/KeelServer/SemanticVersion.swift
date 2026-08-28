/// A dotted numeric version, ordered.
///
/// Deliberately not full semver: no pre-release identifiers, no build metadata, no `+`. App Store
/// and Play Store versions are two to four numbers separated by dots, and supporting the rest of
/// the grammar would mean shipping the pre-release precedence rules — the part of semver that
/// surprises people — to decide whether to *block a user's app*. The gate is the most destructive
/// thing the framework can do, so its comparison stays small enough to hold in your head.
///
/// `1.4` and `1.4.0` are equal: absent components are zero. That matters because an operator
/// typing `minSupportedVersion` by hand writes `1.4`, while `Bundle` reports `1.4.0`.
public struct SemanticVersion: Sendable, Equatable, Comparable, CustomStringConvertible {
    /// Most significant first. At least one component, all non-negative.
    public let components: [Int]

    /// The most components a version may have. Four covers `1.2.3.4`, which is as deep as any
    /// store goes; the bound exists so a pathological query parameter cannot become a long loop.
    static let maximumComponentCount = 4

    /// Parses `1`, `1.4`, `2.1.0`, `1.2.3.4`. Returns nil for anything else.
    ///
    /// Nil is not an error case the callers escalate — every one of them treats an unparseable
    /// version as *un-gated*. Failing open is the only safe direction here: refusing to compare
    /// means the user keeps using the app, while guessing could block every install of a build
    /// whose version string this parser has not met yet.
    public init?(_ text: String) {
        let trimmed = Self.trimmed(text)
        guard !trimmed.isEmpty else { return nil }

        var parsed: [Int] = []
        for field in trimmed.split(separator: ".", omittingEmptySubsequences: false) {
            // Digits only, checked explicitly: `Int("+7")` succeeds, and accepting `1.+4` as
            // `1.4` would be a silent reinterpretation of a string somebody typed wrong. `1..0`
            // and `1.` are rejected for the same reason rather than read as `1.0.0` — guessing
            // what a malformed version meant is how a gate blocks the wrong build.
            guard Self.isASCIIDigits(field), let value = Int(field) else { return nil }
            parsed.append(value)
            guard parsed.count <= Self.maximumComponentCount else { return nil }
        }
        components = parsed
    }

    /// The component at `index`, or 0 past the end — the zero-extension that makes `1.4` and
    /// `1.4.0` compare equal.
    public func component(at index: Int) -> Int {
        index < components.count ? components[index] : 0
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let depth = max(lhs.components.count, rhs.components.count)
        for index in 0..<depth {
            let left = lhs.component(at: index)
            let right = rhs.component(at: index)
            if left != right { return left < right }
        }
        return false
    }

    public static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let depth = max(lhs.components.count, rhs.components.count)
        return (0..<depth).allSatisfy { lhs.component(at: $0) == rhs.component(at: $0) }
    }

    /// As parsed, not as written: `1.4` describes itself as `1.4`, keeping its own depth.
    public var description: String {
        components.map(String.init).joined(separator: ".")
    }

    /// Whitespace-trimmed, without `CharacterSet` — `FoundationEssentials` has no `CharacterSet`,
    /// and this type is otherwise Foundation-free.
    private static func trimmed(_ text: String) -> Substring {
        var slice = text[...]
        while let first = slice.first, first.isWhitespace { slice = slice.dropFirst() }
        while let last = slice.last, last.isWhitespace { slice = slice.dropLast() }
        return slice
    }

    /// Non-empty and every byte an ASCII digit. Bytes rather than `Character.isNumber`, which is
    /// true for `٣` and `½` — neither of which belongs in a version this type will order.
    private static func isASCIIDigits(_ field: Substring) -> Bool {
        !field.isEmpty
            && field.utf8.allSatisfy { $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }
    }
}

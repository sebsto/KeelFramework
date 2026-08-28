import Foundation

@testable import KeelCore

/// Reads the golden fixtures in `Fixtures/` at the repository root.
///
/// Located by walking up from `#filePath` rather than bundled as a SwiftPM resource: a resource
/// has to live inside its own target's directory, which would mean one copy per test target —
/// and two copies of the contract is the exact failure these fixtures exist to catch. See
/// `Fixtures/README.md`.
///
/// `KeelServerTests` has its own copy of this file, differing only in how far it walks up.
enum Fixture {
    /// A file known to sit in the fixture directory, used as the marker while walking up. Any
    /// of them would do; this one is named because it is the smallest.
    private static let marker = "bootstrap-minimal.json"

    private static let directory: URL = {
        var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        // Bounded by the path's own depth — `deletingLastPathComponent` on "/" returns "/", so
        // an unbounded loop here would spin forever if the fixtures were ever moved.
        while candidate.path != "/" {
            let fixtures = candidate.appendingPathComponent("Fixtures")
            if FileManager.default.fileExists(
                atPath: fixtures.appendingPathComponent(marker).path)
            {
                return fixtures
            }
            candidate = candidate.deletingLastPathComponent()
        }
        fatalError("Could not find Fixtures/\(marker) above \(#filePath)")
    }()

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(name))
    }

    /// A fixture parsed into `JSONValue`, for comparison against encoded output.
    static func json(_ name: String) throws -> JSONValue {
        try WireJSON.decoder().decode(JSONValue.self, from: data(name))
    }

    /// Encodes a value and re-reads it as `JSONValue`.
    ///
    /// The comparison is on the JSON, not on the bytes: object key order and whitespace are not
    /// part of the contract, and a test that pinned them would fail on a formatting change and
    /// train everyone to ignore it.
    static func canonical(_ value: some Encodable) throws -> JSONValue {
        try WireJSON.decoder().decode(JSONValue.self, from: WireJSON.encoder().encode(value))
    }

    /// Decodes a fixture into a wire type.
    static func decode<T: Decodable>(_ type: T.Type, from name: String) throws -> T {
        try WireJSON.decoder().decode(type, from: data(name))
    }
}

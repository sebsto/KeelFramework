import Foundation
import KeelServerTesting
import Testing

@testable import KeelServer

/// The legacy envelope behind `envelope: flattened` — the `/station` shape, where the app
/// payload's keys sit beside `features` instead of under `app`.
@Suite("Flattened bootstrap envelope")
struct FlattenedBootstrapTests {

    static let now = TestClock.default

    private static func response(app: JSONValue?) -> BootstrapResponse<JSONValue> {
        BootstrapResponse(
            generatedAt: now,
            features: ["sleep_timer": true],
            app: app)
    }

    private static func keys(_ value: JSONValue) -> Set<String> {
        guard case .object(let object) = value else { return [] }
        return Set(object.keys)
    }

    @Test("The app payload's keys are hoisted beside the framework's")
    func hoistsPayloadKeys() throws {
        let flattened = try Self.response(
            app: .object([
                "name": .string("Maxi 80"),
                "streamURL": .string("https://audio.example.com/stream"),
            ])
        ).flattened()

        guard case .object(let envelope) = flattened else {
            Issue.record("Expected an object")
            return
        }
        #expect(envelope["name"] == .string("Maxi 80"))
        #expect(envelope["streamURL"] == .string("https://audio.example.com/stream"))
        #expect(envelope["features"] == .object(["sleep_timer": .bool(true)]))
        // Hoisted, not copied: an `app` key left behind would make a client that reads both see
        // the payload twice.
        #expect(envelope["app"] == nil)
    }

    @Test("A payload key that collides with a framework key loses")
    func frameworkKeysWin() throws {
        let flattened = try Self.response(
            app: .object(["features": .string("impostor"), "extra": .int(1)])
        ).flattened()

        guard case .object(let envelope) = flattened else {
            Issue.record("Expected an object")
            return
        }
        // The framework's `features` is the flag mechanism; a payload must not be able to mask
        // it, accidentally or otherwise.
        #expect(envelope["features"] == .object(["sleep_timer": .bool(true)]))
        #expect(envelope["extra"] == .int(1))
    }

    @Test("No payload flattens to the canonical shape minus `app`")
    func noPayload() throws {
        let flattened = try Self.response(app: nil).flattened()
        #expect(!Self.keys(flattened).contains("app"))
        #expect(Self.keys(flattened).contains("features"))
        #expect(Self.keys(flattened).contains("telemetry"))
    }

    @Test("A payload that is not an object stays under `app`")
    func nonObjectPayloadStaysPut() throws {
        let flattened = try Self.response(app: .array([.int(1), .int(2)])).flattened()
        guard case .object(let envelope) = flattened else {
            Issue.record("Expected an object")
            return
        }
        // There is nothing to hoist — an array has no keys — and inventing a place for it would
        // produce a shape no legacy client ever had.
        #expect(envelope["app"] == .array([.int(1), .int(2)]))
    }

    @Test("Flattening changes nothing the canonical encoding says")
    func preservesCanonicalFields() throws {
        let flattened = try Self.response(app: .object(["x": .int(1)])).flattened()
        guard case .object(let envelope) = flattened else {
            Issue.record("Expected an object")
            return
        }
        // Spot-check the fields the canonical `encode(to:)` computes rather than copies, so a
        // future rewrite of `flattened()` cannot quietly re-implement encoding.
        #expect(envelope["schemaVersion"] == .int(Keel.schemaVersion))
        #expect(envelope["generatedAt"] == .string("2026-08-24T10:00:00Z"))
    }
}

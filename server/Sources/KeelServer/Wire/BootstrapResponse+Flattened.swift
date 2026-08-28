#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

extension BootstrapResponse {
    /// This response with the `app` payload's keys hoisted to the top level — the legacy
    /// envelope an alias route can opt into (`AliasRoutes.Envelope.flattened`).
    ///
    /// Maxi80's `/station` returns station fields *beside* `features`, not under an `app` key,
    /// and shipped clients decode that shape. Flattening at the edge lets those clients keep
    /// working against a Keel backend while the stored config stays canonical.
    ///
    /// Implemented as encode-then-merge rather than by rebuilding the object field by field, so
    /// the canonical `encode(to:)` — with its omission rules and date formatting — stays the
    /// single place that decides what goes on the wire; this only moves keys.
    ///
    /// Merge rules, each chosen for the retrofit case:
    /// - A payload key that collides with a framework key loses. The framework's `features` must
    ///   not be maskable by an app payload that happens to declare one.
    /// - A payload that is not a JSON object (an array, a bare string) cannot be flattened and
    ///   stays under `app` — a legacy client would not have had such a payload anyway.
    public func flattened() throws -> JSONValue {
        let encoded = try WireJSON.encoder().encode(self)
        let decoded = try WireJSON.decoder().decode(JSONValue.self, from: encoded)
        guard case .object(var envelope) = decoded else { return decoded }
        guard case .object(let payload) = envelope["app"] else { return decoded }

        envelope["app"] = nil
        for (key, value) in payload where envelope[key] == nil {
            envelope[key] = value
        }
        return .object(envelope)
    }
}

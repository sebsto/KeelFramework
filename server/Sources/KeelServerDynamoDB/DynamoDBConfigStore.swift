public import KeelServer
public import KeelSotoDynamoDB

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// `ConfigStore` on the same table: the one `CONFIG#current` / `v1` item.
///
/// The config travels as a JSON string in a `payload` attribute rather than as a DynamoDB map.
/// One attribute means the item's shape never chases `RemoteConfig`'s, `keel config get` can
/// print the payload verbatim, and an operator editing it in the console edits JSON — a format
/// with a validator on every machine — instead of the console's attribute tree.
public struct DynamoDBConfigStore: ConfigStore {
    let dynamoDB: DynamoDB
    let tableName: String

    public init(dynamoDB: DynamoDB, tableName: String) {
        self.dynamoDB = dynamoDB
        self.tableName = tableName
    }

    public func load() async throws -> RemoteConfig? {
        let output = try await dynamoDB.getItem(
            DynamoDB.GetItemInput(
                key: [
                    "pk": .s(CounterSchema.configPartitionKey),
                    "sk": .s(CounterSchema.configSortKey),
                ],
                tableName: tableName))
        guard let item = output.item else { return nil }
        guard case .s(let payload) = item["payload"] else {
            // An item without a payload is a hand-edit that went wrong. Nil would serve
            // compiled-in defaults silently; a decode error is the louder, correcter answer,
            // and `ConfigCache` turns it into "last known good" rather than an outage.
            throw ConfigItemError.missingPayload
        }
        return try WireJSON.decoder().decode(RemoteConfig.self, from: Data(payload.utf8))
    }

    public func save(_ config: RemoteConfig) async throws {
        var stamped = config
        stamped.updatedAt = Date()
        let payload = try WireJSON.encoder().encode(stamped)
        _ = try await dynamoDB.putItem(
            DynamoDB.PutItemInput(
                item: [
                    "pk": .s(CounterSchema.configPartitionKey),
                    "sk": .s(CounterSchema.configSortKey),
                    "payload": .s(String(decoding: payload, as: UTF8.self)),
                ],
                tableName: tableName))
    }
}

/// What can be wrong with the stored config item itself, as opposed to the table being
/// unreachable. Kept separate so a log line names the actual problem.
public enum ConfigItemError: Error, Sendable, Equatable {
    /// The item exists but has no `payload` attribute — a hand-edit gone wrong.
    case missingPayload
}

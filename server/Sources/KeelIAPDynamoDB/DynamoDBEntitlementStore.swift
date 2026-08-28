public import KeelIAP
import KeelServer
public import SotoDynamoDB

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// `EntitlementStore` on the same single Keel table as the counters.
///
/// Entitlements travel as JSON in a `payload` attribute, the same convention as the
/// config item: one attribute means the item shape never chases the Swift type, and the
/// console shows something a human can read during a support conversation.
public struct DynamoDBEntitlementStore: EntitlementStore {
    let dynamoDB: DynamoDB
    let tableName: String

    public init(dynamoDB: DynamoDB, tableName: String) {
        self.dynamoDB = dynamoDB
        self.tableName = tableName
    }

    public func entitlements(userId: String) async throws -> [Entitlement] {
        let output = try await dynamoDB.query(
            DynamoDB.QueryInput(
                expressionAttributeValues: [
                    ":pk": .s(EntitlementSchema.userPartitionKey(userId: userId))
                ],
                keyConditionExpression: "pk = :pk",
                tableName: tableName))
        // Bounded by the number of products the app sells, so no pagination loop: a page
        // holds 1 MB, and no app sells that many SKUs.
        return (output.items ?? []).compactMap { item in
            guard case .s(let payload) = item["payload"] else { return nil }
            return try? WireJSON.decoder().decode(Entitlement.self, from: Data(payload.utf8))
        }
    }

    public func save(_ entitlement: Entitlement, userId: String) async throws {
        let payload = try WireJSON.encoder().encode(entitlement)
        _ = try await dynamoDB.putItem(
            DynamoDB.PutItemInput(
                item: [
                    "pk": .s(EntitlementSchema.userPartitionKey(userId: userId)),
                    "sk": .s(entitlement.productId),
                    "payload": .s(String(decoding: payload, as: UTF8.self)),
                ],
                tableName: tableName))
    }

    public func owner(originalTransactionId: String) async throws -> TransactionOwner? {
        let output = try await dynamoDB.getItem(
            DynamoDB.GetItemInput(
                key: [
                    "pk": .s(
                        EntitlementSchema.transactionPartitionKey(
                            originalTransactionId: originalTransactionId)),
                    "sk": .s(EntitlementSchema.transactionSortKey),
                ],
                tableName: tableName))
        guard let item = output.item, case .s(let payload) = item["payload"] else { return nil }
        return try? WireJSON.decoder().decode(TransactionOwner.self, from: Data(payload.utf8))
    }

    public func saveOwner(
        _ owner: TransactionOwner, originalTransactionId: String
    ) async throws {
        let payload = try WireJSON.encoder().encode(owner)
        _ = try await dynamoDB.putItem(
            DynamoDB.PutItemInput(
                item: [
                    "pk": .s(
                        EntitlementSchema.transactionPartitionKey(
                            originalTransactionId: originalTransactionId)),
                    "sk": .s(EntitlementSchema.transactionSortKey),
                    "payload": .s(String(decoding: payload, as: UTF8.self)),
                ],
                tableName: tableName))
    }
}

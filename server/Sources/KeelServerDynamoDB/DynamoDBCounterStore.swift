public import KeelServer
public import SotoDynamoDB

/// `CounterStore` on the single Keel table.
///
/// Expression-based `UpdateItem` rather than any Codable mapping layer, because such layers have
/// no `ADD` action. `ADD` is what lets any number of devices increment one row with no read, no
/// conditional write, and no per-device state (`docs/ARCHITECTURE.md` §4).
public struct DynamoDBCounterStore: CounterStore {
    let dynamoDB: DynamoDB
    let tableName: String

    public init(dynamoDB: DynamoDB, tableName: String) {
        self.dynamoDB = dynamoDB
        self.tableName = tableName
    }

    public func increment(_ write: CounterWrite) async throws {
        var names = ["#count": "count"]
        var values: [String: DynamoDB.AttributeValue] = [":one": .n("1")]
        var updateExpression = "ADD #count :one"
        if let ttl = write.ttl {
            names["#ttl"] = "ttl"
            values[":ttl"] = .n(String(ttl))
            // Anchored to the counter's *first* increment: every later ping of the same day
            // re-sends the same nominal expiry, and moving it would keep a hot counter alive
            // past the window the privacy docs promise.
            updateExpression += " SET #ttl = if_not_exists(#ttl, :ttl)"
        }
        _ = try await dynamoDB.updateItem(
            DynamoDB.UpdateItemInput(
                expressionAttributeNames: names,
                expressionAttributeValues: values,
                key: ["pk": .s(write.partitionKey), "sk": .s(write.sortKey)],
                tableName: tableName,
                updateExpression: updateExpression))
    }

    public func query(partitionKey: String, sortKeyFrom: String?) async throws -> [CounterRow] {
        var values: [String: DynamoDB.AttributeValue] = [":pk": .s(partitionKey)]
        var keyCondition = "pk = :pk"
        if let sortKeyFrom {
            values[":from"] = .s(sortKeyFrom)
            keyCondition += " AND sk >= :from"
        }

        // `count` is a DynamoDB reserved word — it has to be aliased even in a projection.
        let input = DynamoDB.QueryInput(
            expressionAttributeNames: ["#c": "count"],
            expressionAttributeValues: values,
            keyConditionExpression: keyCondition,
            projectionExpression: "sk, #c",
            tableName: tableName)

        var rows: [CounterRow] = []
        for try await page in dynamoDB.queryPaginator(input) {
            for item in page.items ?? [] {
                guard case .s(let sortKey) = item["sk"] else { continue }
                // An `AGG#` item without a numeric count has been tampered with by hand;
                // reading it as zero keeps the page honest about what the table now says.
                let count: Int
                if case .n(let raw) = item["count"], let parsed = Int(raw) {
                    count = parsed
                } else {
                    count = 0
                }
                rows.append(CounterRow(sortKey: sortKey, count: count))
            }
        }
        return rows
    }
}

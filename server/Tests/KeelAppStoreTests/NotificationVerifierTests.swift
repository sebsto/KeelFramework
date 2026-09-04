import AWSLambdaEvents
import Foundation
import HTTPTypes
import KeelAppStoreRouter
import KeelAppStoreTesting
import Logging
import Routing
import Testing

@testable import KeelAppStore

/// The notification verifier's happy path and rejection paths, and the `mount(appStore:)`
/// round-trip: a verified payload reaches the handler and the route acks 200, while an
/// unverifiable one never reaches the handler and does not ack.
@Suite("App Store notification verification + mount seam")
struct NotificationVerifierTests {

    private func verifier() -> NotificationVerifier {
        NotificationVerifier(pinnedRoots: [TestPKI.root], validationTime: TestPKI.start)
    }

    // MARK: - Verifier

    @Test("A known-good notification verifies and its inner transaction decodes")
    func goodNotification() async throws {
        let payload = try await verifier().verify(
            TestPKI.notificationJWS(type: "REFUND"))
        #expect(payload.notificationType == .refund)
        #expect(payload.notificationUUID == "b1c9b1c9-0000-4000-8000-000000000000")
        let inner = try #require(payload.signedTransactionInfo)
        let transaction = try await verifier().verifyTransactionInfo(inner)
        #expect(transaction.productId == "unlock_pro")
        #expect(transaction.bundleId == "com.example.app")
    }

    @Test("An unknown notification type is a value, not a decode failure")
    func unknownTypeIsAValue() async throws {
        let payload = try await verifier().verify(
            TestPKI.notificationJWS(type: "SOME_FUTURE_TYPE"))
        // The whole point of the open enum: Apple can add a type and it arrives verbatim.
        #expect(payload.notificationType == AppStoreNotificationType(rawValue: "SOME_FUTURE_TYPE"))
        #expect(payload.notificationType != .refund)
    }

    @Test("A TEST notification with no inner transaction still verifies")
    func testNotificationWithoutTransaction() async throws {
        let payload = try await verifier().verify(
            TestPKI.notificationJWS(type: "TEST", includeTransaction: false))
        #expect(payload.signedTransactionInfo == nil)
    }

    @Test("A tampered notification is rejected as a bad signature")
    func tamperedNotification() async {
        let jws = TestPKI.makeJWS(claims: ["notificationType": "REFUND"], tamper: true)
        await #expect(throws: JWSVerificationError.self) {
            _ = try await verifier().verify(jws)
        }
    }

    // MARK: - mount(appStore:) round-trip

    @Test("A verified notification reaches the handler and the route acks 200")
    func mountVerifiedReachesHandlerAndAcks() async throws {
        let handled = Handled()
        let builder = HTTPRouterBuilder()
        builder.mount(appStore: verifier(), logger: Self.quietLogger()) { notification in
            await handled.record(notification.notificationType.rawValue)
        }
        let router = builder.build()

        let resp = await router.handle(
            try makeNotificationPOST(signedPayload: TestPKI.notificationJWS(type: "REFUND")),
            logger: Self.quietLogger())

        #expect(resp.statusCode.code == 200)
        #expect(await handled.types == ["REFUND"])
    }

    @Test("A bad signature returns non-2xx and the handler is never called")
    func mountBadSignatureDoesNotCallHandler() async throws {
        let handled = Handled()
        let builder = HTTPRouterBuilder()
        builder.mount(appStore: verifier(), logger: Self.quietLogger()) { notification in
            await handled.record(notification.notificationType.rawValue)
        }
        let router = builder.build()

        let resp = await router.handle(
            try makeNotificationPOST(signedPayload: "not.a.valid.jws"),
            logger: Self.quietLogger())

        #expect(resp.statusCode.code != 200)
        #expect(await handled.types.isEmpty)
    }

    // MARK: - KeelAppStoreTesting factory

    @Test("The testing factory builds a verified-payload value without a verifier")
    func testingFactoryBuildsPayload() {
        let payload = KeelAppStoreFixtures.notificationPayload(
            notificationType: .refund, notificationUUID: "u")
        #expect(payload.notificationType == .refund)

        let info = KeelAppStoreFixtures.signedTransactionInfo(productId: "sub_monthly")
        #expect(info.productId == "sub_monthly")
    }

    // MARK: - Helpers

    private static func quietLogger() -> Logger {
        var logger = Logger(label: "test")
        logger.logLevel = .critical
        return logger
    }
}

/// A tiny actor to record what the mount handler saw, across the `await router.handle`.
private actor Handled {
    private(set) var types: [String] = []
    func record(_ type: String) { types.append(type) }
}

/// Build a `POST /v1/appstore-notification` `HTTPRequest` carrying `{ "signedPayload": … }`.
private func makeNotificationPOST(signedPayload: String) throws -> Routing.HTTPRequest {
    let path = "/v1/appstore-notification"
    let bodyJSON = try String(
        decoding: JSONSerialization.data(withJSONObject: ["signedPayload": signedPayload]),
        as: UTF8.self)
    // Escape for embedding in the outer event JSON string.
    let escapedBody =
        bodyJSON
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")

    let json = """
        {
          "version": "2.0",
          "routeKey": "POST \(path)",
          "rawPath": "\(path)",
          "rawQueryString": "",
          "isBase64Encoded": false,
          "headers": { "host": "test.example.com", "content-type": "application/json" },
          "pathParameters": { "proxy": "\(path.dropFirst())" },
          "body": "\(escapedBody)",
          "requestContext": {
            "accountId": "123456789012",
            "apiId": "test",
            "stage": "$default",
            "domainName": "test.example.com",
            "domainPrefix": "test",
            "requestId": "test-request-id",
            "time": "02/Sep/2026:10:00:00 +0000",
            "timeEpoch": 1756792800000,
            "http": {
              "method": "POST",
              "path": "\(path)",
              "protocol": "HTTP/1.1",
              "sourceIp": "127.0.0.1",
              "userAgent": "TestSuite/1.0"
            }
          }
        }
        """
    let event = try JSONDecoder().decode(APIGatewayV2Request.self, from: Data(json.utf8))
    return Routing.HTTPRequest(event: event)
}

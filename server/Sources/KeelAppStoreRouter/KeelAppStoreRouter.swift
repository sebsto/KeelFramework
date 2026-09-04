import AWSLambdaEvents
import HTTPTypes
public import KeelAppStore
import KeelServer
public import Logging
public import Routing

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// The single App Store notification route, mounted beside `KeelRouter`'s three, only by apps
/// that opt in.
///
/// ```swift
/// builder.mount(keel: keel)
/// builder.mount(appStore: verifier) { notification in
///     // app-owned side effect on a verified notification
/// }
/// ```
///
/// The helper OWNS the four things an adopting app would otherwise have to get right from prose
/// — and get wrong silently: the route **path**, the raw-body **read**, the **verify** call, and
/// the **200 ack** that stops Apple retrying. The only thing the app writes is the side effect,
/// so it cannot forget the plumbing it never wrote.
///
/// The route is public by necessity — Apple's servers hold no credentials of ours — and safe
/// because verification *is* the authentication: an unverifiable payload gets a non-2xx and
/// changes nothing, so an anonymous caller can do nothing here but collect one.
///
/// A separate module from `KeelRouter` so an app without server-side App Store verification
/// links neither this nor the X.509 stack under it.
public struct KeelAppStoreRouter: Sendable {
    /// The canonical notification route path. Mirrored in `cdk/lib/contract.ts` as
    /// `KEEL_APPSTORE_NOTIFICATION_ROUTE` and held equal by the CDK contract test.
    public static let notificationPath = "/v1/appstore-notification"

    let verifier: NotificationVerifier
    let handler: @Sendable (NotificationPayload) async throws -> Void
    let logger: Logger

    public init(
        verifier: NotificationVerifier,
        logger: Logger = Logger(label: "keel.appstore"),
        onNotification handler: @escaping @Sendable (NotificationPayload) async throws -> Void
    ) {
        self.verifier = verifier
        self.handler = handler
        self.logger = logger
    }

    func register(on builder: HTTPRouterBuilder) {
        builder.on(Routing.HTTPRequest.post(Self.notificationPath)) { request, _ in
            await self.handle(request)
        }
    }

    /// The body of `POST /v1/appstore-notification`, as Apple sends it.
    private struct NotificationRequest: Decodable {
        let signedPayload: String
    }

    /// The acknowledgement Apple expects: any 2xx. The body is for humans reading traces.
    private struct NotificationAck: Encodable, Sendable {
        var ok = true
    }

    private func handle(_ request: Routing.HTTPRequest) async -> RouteResponse {
        let signedPayload: String
        do {
            signedPayload = try WireJSON.decoder()
                .decode(NotificationRequest.self, from: request.body).signedPayload
        } catch {
            return Self.response(for: .badRequest(field: "body", reason: "not a valid request"))
        }

        let notification: NotificationPayload
        do {
            notification = try await verifier.verify(signedPayload)
        } catch {
            // The specific failure goes to the log; the caller gets one undifferentiated
            // rejection. An unverifiable payload is not from Apple, so nothing runs.
            logger.warning(
                "Rejected an App Store notification", metadata: ["reason": "\(error)"])
            return Self.response(
                for: .badRequest(field: "signedPayload", reason: "not a verifiable payload"))
        }

        logger.info(
            "App Store notification",
            metadata: [
                "type": .string(notification.notificationType.rawValue),
                "subtype": .string(notification.subtype ?? "-"),
                "uuid": .string(notification.notificationUUID),
            ])

        do {
            try await handler(notification)
        } catch {
            // The app's side effect failed. Apple retries on a non-2xx, which is the right
            // behaviour for a transient store failure — but the payload was genuine, so log it.
            logger.error(
                "App Store notification handler failed", metadata: ["error": "\(error)"])
            return .error(statusCode: .internalServerError, message: "Notification handling failed")
        }

        // The 200 ack: verified and handled, so Apple stops retrying.
        return .json(NotificationAck(), statusCode: .ok)
    }

    private static func response(for error: KeelError) -> RouteResponse {
        .json(ErrorResponse(error), statusCode: .init(code: error.statusCode))
    }
}

extension HTTPRouterBuilder {
    /// Add the App Store notification endpoint to this builder, beside `mount(keel:)`'s three.
    ///
    /// The helper owns the path, the raw-body read, the verify call, the failure→status
    /// mapping, and the 200 ack; the closure is the app's side effect on a verified payload.
    public func mount(
        appStore verifier: NotificationVerifier,
        logger: Logger = Logger(label: "keel.appstore"),
        onNotification handler: @escaping @Sendable (NotificationPayload) async throws -> Void
    ) {
        KeelAppStoreRouter(verifier: verifier, logger: logger, onNotification: handler)
            .register(on: self)
    }
}

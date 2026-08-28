import AWSLambdaEvents
import HTTPTypes
public import KeelIAP
import KeelServer
import Logging
public import Routing

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// The IAP route table: mounted beside `KeelRouter`'s three, only by apps that opted in.
///
/// ```swift
/// builder.mount(keel: keel)
/// builder.mount(keelIAP: iap)
/// ```
///
/// A separate module from `KeelRouter` so an app without server-side IAP links neither
/// this nor the X.509 stack under it.
public struct KeelIAPRouter: Sendable {
    let purchase: PurchaseHandler
    let entitlement: EntitlementHandler
    let notification: NotificationHandler

    public init(
        purchase: PurchaseHandler,
        entitlement: EntitlementHandler,
        notification: NotificationHandler
    ) {
        self.purchase = purchase
        self.entitlement = entitlement
        self.notification = notification
    }

    func register(on builder: HTTPRouterBuilder) {
        builder.on(Routing.HTTPRequest.post("/v1/purchase")) { request, _ in
            await self.handle(request) { body in
                try await self.purchase.handle(
                    WireJSON.decoder().decode(PurchaseRequest.self, from: body))
            }
        }
        builder.get("/v1/entitlement") { request, _ in
            guard let userId = request.event.queryStringParameters["userId"] else {
                return Self.response(
                    for: .badRequest(field: "userId", reason: "is required"))
            }
            do {
                return .json(try await self.entitlement.handle(userId: userId), statusCode: .ok)
            } catch let error as KeelError {
                return Self.response(for: error)
            }
        }
        builder.on(Routing.HTTPRequest.post("/v1/appstore-notification")) { request, _ in
            await self.handle(request) { body in
                try await self.notification.handle(
                    WireJSON.decoder().decode(NotificationRequest.self, from: body))
            }
        }
    }

    /// Decode-and-dispatch with the same error policy as the core routes: a `KeelError`
    /// becomes its own status, an undecodable body a field-free 400, and nothing from
    /// the body is ever echoed.
    private func handle(
        _ request: Routing.HTTPRequest,
        _ body: @Sendable (Data) async throws -> some Encodable & Sendable
    ) async -> RouteResponse {
        do {
            return .json(try await body(request.body), statusCode: .ok)
        } catch let error as KeelError {
            return Self.response(for: error)
        } catch is DecodingError {
            return Self.response(for: .badRequest(field: "body", reason: "not a valid request"))
        } catch {
            return .error(statusCode: .internalServerError, message: "Request failed")
        }
    }

    private static func response(for error: KeelError) -> RouteResponse {
        .json(ErrorResponse(error), statusCode: .init(code: error.statusCode))
    }
}

extension HTTPRouterBuilder {
    /// Add the IAP endpoints to this builder, beside `mount(keel:)`'s three.
    public func mount(keelIAP: KeelIAPRouter) {
        keelIAP.register(on: self)
    }
}

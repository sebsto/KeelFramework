import AWSLambdaRuntime
import KeelServer
import NIOCore

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// An event decoder that fills in `pathParameters.proxy` from `rawPath` when absent.
///
/// lambda-kit's `HTTPRequest.routingKey` reads the `proxy` path parameter, which API Gateway
/// populates only for `{proxy+}` routes. Keel's infrastructure declares **explicit** routes
/// instead (`GET /v1/bootstrap`, …), because explicit routes are what let one path carry an
/// authorizer while `publicRoutes` go without (`docs/ARCHITECTURE.md` §8) — and on those
/// events the parameter never arrives. Patching the raw JSON before it becomes a typed event
/// keeps full event fidelity (authorizer context included) without maintaining a hand-written
/// mutable mirror of `APIGatewayV2Request`, which is not `Encodable`.
///
/// `rawPath` is the stage-relative path because Keel deploys on the `$default` stage; a named
/// stage would prefix it, and nothing here strips one.
struct ProxySynthesizingDecoder: LambdaEventDecoder {
    func decode<Event: Decodable>(_ type: Event.Type, from buffer: ByteBuffer) throws -> Event {
        let data = Data(buffer.readableBytesView)
        guard
            let tree = try? WireJSON.decoder().decode(JSONValue.self, from: data),
            case .object(var event) = tree,
            case .string(let rawPath) = event["rawPath"]
        else {
            // Not an API Gateway v2 shape — hand it through and let the typed decode say why.
            return try WireJSON.decoder().decode(Event.self, from: data)
        }

        var parameters: [String: JSONValue] =
            if case .object(let existing) = event["pathParameters"] { existing } else { [:] }
        if parameters["proxy"] == nil {
            parameters["proxy"] = .string(String(rawPath.drop(while: { $0 == "/" })))
            event["pathParameters"] = .object(parameters)
        }
        return try WireJSON.decoder().decode(
            Event.self, from: WireJSON.encoder().encode(JSONValue.object(event)))
    }
}

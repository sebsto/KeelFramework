import AWSLambdaEvents
import AWSLambdaRuntime
import Configuration
import KeelSotoSSM
import Logging

/// The `sharedSecret` authorizer: one secret, read from SSM Parameter Store at cold start,
/// compared against the `Authorization` header of every request API Gateway forwards.
///
/// This is deliberately the simplest auth that keeps a public endpoint from being anonymous
/// traffic (`docs/ARCHITECTURE.md` §8). It authenticates the *app*, not a user — every install
/// ships the same secret, so treat it as a tripwire against casual abuse, not a boundary against
/// a motivated attacker with a copy of the binary. Deployments needing user identity pick the
/// `jwt` or `iam` mode instead, which have no Lambda at all.
@main
struct KeelAuthorizerLambda: LambdaHandler {
    private let expectedSecret: String

    init() async throws {
        let config = ConfigReader(provider: EnvironmentVariablesProvider())
        guard let parameterName = config.string(forKey: "secretParameter", isSecret: false),
            !parameterName.isEmpty
        else {
            throw AuthorizerError.missingSecretParameter
        }

        var logger = Logger(label: "keel.authorizer")
        logger.logLevel =
            config.string(forKey: "logLevel").flatMap(Logger.Level.init(rawValue:)) ?? .info

        // Read once at cold start and held for the life of the process. Rotating the parameter
        // therefore needs the function's environment touched (any no-op update) to force new
        // cold starts — documented on the CDK construct, which owns the rotation story.
        let ssm = SSM(client: AWSClient())
        let response = try await ssm.getParameter(
            SSM.GetParameterRequest(name: parameterName, withDecryption: true))
        guard let secret = response.parameter?.value, !secret.isEmpty else {
            throw AuthorizerError.emptySecret(parameterName: parameterName)
        }
        self.expectedSecret = secret
        logger.info("Authorizer initialized")
    }

    func handle(
        _ request: APIGatewayLambdaAuthorizerRequest, context: LambdaContext
    ) async throws -> APIGatewayLambdaAuthorizerSimpleResponse {
        let header = request.headers["authorization"] ?? request.headers["Authorization"]
        let isAuthorized = header.map(matches) ?? false
        if !isAuthorized {
            // The header value is a credential attempt — wrong or not, it is never logged.
            context.logger.warning("Unauthorized request")
        }
        return APIGatewayLambdaAuthorizerSimpleResponse(isAuthorized: isAuthorized, context: nil)
    }

    /// Accepts `Bearer <secret>` and the raw secret, compared in constant time.
    ///
    /// Constant-time because this runs on every request with an attacker-supplied left side:
    /// `==` short-circuits at the first differing byte, and response-time differences are the
    /// classic way a secret leaks a prefix at a time. XOR-accumulating over the full length
    /// gives nothing to measure.
    private func matches(_ header: String) -> Bool {
        let presented = header.hasPrefix("Bearer ") ? String(header.dropFirst(7)) : header
        let lhs = Array(presented.utf8)
        let rhs = Array(expectedSecret.utf8)
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) {
            difference |= left ^ right
        }
        return difference == 0
    }

    static func main() async throws {
        let handler = try await KeelAuthorizerLambda()
        let runtime = LambdaRuntime(lambdaHandler: handler)
        try await runtime.run()
    }
}

enum AuthorizerError: Error {
    /// `SECRET_PARAMETER` is unset. The authorizer would otherwise deny everything, which
    /// looks identical to a client bug from the outside — better to never come up.
    case missingSecretParameter

    /// The parameter exists but holds nothing.
    case emptySecret(parameterName: String)
}

# 0002 — swift-aws-lambda-runtime 3.x and a fork of lambda-kit

**Status:** accepted, with an exit plan · 2026-08-24

## Context

The server needs an HTTP router over API Gateway events. The candidates:

1. **Hummingbird** on the Lambda runtime — mature, but pulls NIO's full server stack into
   a 128 MB function and lengthens cold start for a router we use three times.
2. **`SongShift/lambda-kit`'s `Routing` library** — a small, typed router built exactly for
   this shape (`HTTPRouterBuilder`, typed path parameters, `APIGatewayV2Server` for local
   development). Maxi80 already uses it in production. But upstream pins
   `swift-aws-lambda-runtime` at 2.6.x, and we want 3.x for its `LambdaRuntime` API,
   response streaming, and the `AWSLambdaBuilder` plugin that CDK reads its zip from.
3. **Write our own** — roughly 150 lines for method + path matching with parameters.

## Decision

Use `swift-aws-lambda-runtime` **3.0.0-rc1** and `sebsto/lambda-kit` branch
`support-runtime-3`, taking the `Routing` library only.

Two facts make the fork cheap rather than alarming: `Routing` does not itself depend on the
Lambda runtime — the pin is transitive metadata, not code coupling — and the fork widens a
version range without changing behaviour. `Package.resolved` pins the commit
(`5b2b0256`), so a force-push on the branch cannot silently change what we build.

`DynamoQueries` (lambda-kit's `@Table` macro) is deliberately **not** adopted for the
counter table: every write there is an `ADD` on a key `CounterSchema` builds, which the
macro does not model. It remains a good candidate for the IAP entitlement items.

## Consequences

**Good.** Small dependency surface, fast cold start, a router we already trust in
production, and `APIGatewayV2Server` gives a real local `curl`-able server without SAM or
Docker.

**Bad.** Two pre-release/non-upstream pins in the dependency graph of a framework meant to
be boring. A consuming app inherits both. An `rc` runtime can still change API before 3.0.

## Exit criteria

Any one of these retires this ADR:

1. Upstream lambda-kit widens its runtime pin to 3.x → drop the fork, keep the library.
2. `swift-aws-lambda-runtime` 3.0.0 final ships → change `from: "3.0.0-rc1"` to
   `from: "3.0.0"` and re-resolve.
3. Either becomes unmaintained → replace `Routing` with the ~150-line router. This is the
   reason `KeelServer` never imports `Routing`: the handlers are plain
   `(Request) async throws -> Response` functions and only `KeelLambda` knows the router
   exists, so swapping it touches one file.

Point 3 is the load-bearing mitigation. The fork is a convenience, not a dependency the
design rests on.

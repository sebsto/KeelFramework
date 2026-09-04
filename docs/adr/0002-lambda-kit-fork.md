# 0002 — swift-aws-lambda-runtime 3.x and a fork of lambda-kit

**Status:** accepted, with an exit plan · 2026-08-24

## Context

The server needs an HTTP router over API Gateway events. The candidates:

1. **Hummingbird** on the Lambda runtime — mature, but pulls NIO's full server stack into
   a 128 MB function and lengthens cold start for a router we use three times.
2. **`SongShift/lambda-kit`'s `Routing` library** — a small, typed router built exactly for
   this shape (`HTTPRouterBuilder`, typed path parameters, `APIGatewayV2Server` for local
   development), and it is already used in production elsewhere. But upstream pins
   `swift-aws-lambda-runtime` at 2.6.x, and we want 3.x for its `LambdaRuntime` API,
   response streaming, and the `AWSLambdaBuilder` plugin that CDK reads its zip from.
3. **Write our own** — roughly 150 lines for method + path matching with parameters.

## Decision

Use `swift-aws-lambda-runtime` **3.0.0-rc1** and `sebsto/lambda-kit` fork
(`github.com/sebsto/lambda-kit`), taking the `Routing` library only. `Package.swift` pins the
dependency to the **exact version `0.1.0`**, which tags the Routing-only commit on the fork's
`support-runtime-3` line, so a force-push cannot silently change what builds.

The pin has to be a *version* rather than a revision, because SwiftPM refuses to resolve a
package requested by version whose own dependencies are requested by revision or branch. Keel
is consumed by tag (`from: "0.1.0"`), so every dependency it declares must be
version-pinned too, or no app could depend on Keel at all.

Two facts make the fork cheap rather than alarming: `Routing` does not itself depend on the
Lambda runtime — the pin is transitive metadata, not code coupling — and the fork widens a
version range without changing behaviour.

`DynamoQueries` (lambda-kit's `@Table` macro) is deliberately **not** adopted for the
counter table: every write there is an `ADD` on a key `CounterSchema` builds, which the
macro does not model. (An earlier draft floated it for the IAP entitlement items; those were
removed from the framework — `KeelAppStore` verifies App Store paperwork and stores nothing —
so the macro has no candidate left here.)

## App-side compatibility

An app that mounts Keel beside its own Lambdas (via `builder.mount(keel:)`) shares the same
SPM build graph and therefore **must resolve the same two pins**:

- `swift-aws-lambda-runtime` on the **3.x major** (`3.0.0-rc1` today).
- `lambda-kit` at **exact version `0.1.0`** — or leave its `Package.swift` silent on
  `lambda-kit` and let SPM inherit Keel's pin, which is the simpler path.

A conflicting declaration causes SPM to reject the build. See
[docs/INTEGRATION.md](../INTEGRATION.md) for the setup steps.

**The fork is temporary.** It carries no behaviour the codebase actually uses — it only
widens a version range. It goes away the moment upstream `lambda-kit` depends on
`swift-aws-lambda-runtime` v3, at which point Keel repoints the dependency to a tagged
upstream `lambda-kit` release. That is a `Package.swift`-only change with **no
code** to touch in Keel or any consuming app.

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

# 0005 — Two client modules, so Skip stays possible

**Status:** accepted · 2026-08-24

## Context

An adopting app may ship the same Swift source to Android through [Skip](https://skip.tools), which
transpiles Swift to Kotlin. Skip supports a subset: no `Observation`, no `os.Logger`, no
`StoreKit`, and a narrow slice of Foundation. An app that isn't cross-platform should not
pay anything for this.

## Decision

Split the client package in two.

**`KeelCore`** — portable. Wire types, `HTTPTransport` + `URLSessionTransport` (guarded for
`FoundationNetworking`), `BackendClient` with its 3-second budget, and the pure decision
logic: `PingFlags.compute`, `VersionGate.evaluate`, `FeatureFlagSet`. Constraints, enforced
by review and by a consuming app's Android build rather than by anything in `Package.swift`:

- no `Observation`, no `@Observable`
- no `os.Logger` — a `KeelLog` protocol shim instead
- no `StoreKit`, no `Security`/Keychain
- no `Calendar`/`DateFormatter` outside the one UTC helper
- no macros

**`KeelClient`** — Apple platforms. `@Observable @MainActor` stores, SwiftUI views,
StoreKit 2, the disk cache. Depends on `KeelCore`.

Nothing in the manifest depends on Skip, so an Apple-only app resolves nothing extra and
compiles nothing it doesn't use.

## Consequences

**Good.** An Android target can use the transport, the models, and every decision
function — which is where the logic that must not diverge lives. Two modules is also just
a good split for an Apple-only app: the pure layer is trivially unit-testable with no
`@MainActor` hop and no observation machinery.

**Bad.** The split is enforced by discipline, not by the compiler: an Apple-only developer
can add `@Observable` to `KeelCore` and nothing will complain until someone's Android build
breaks. `Sources/KeelCore/README.md` states the rules at the point of temptation, which is
the best available mitigation short of adding a Skip build to CI. If Skip adoption ever
becomes real for more than one app, add that CI job and delete this paragraph.

The generic `FeatureFlags<Flag>` lives in `KeelClient` because it is `@Observable`, while
its value-type engine `FeatureFlagSet` lives in `KeelCore`. Two types for one concept is the
cost of the split; the `@Observable` one is a thin shell over the testable one.

# Keel

The backend every one of my apps ends up needing, written once.

- **Bootstrap** — remote config, feature flags, and a version gate / kill switch, fetched at
  launch so behaviour changes without an App Store release.
- **Ping** — anonymous usage counters with a public stats endpoint and a dashboard.

Swift 6 client for Apple platforms, Swift 6 Lambda backend, TypeScript CDK stack, and a
static dashboard. Opinionated about structure; agnostic about what your app is — free, paid,
IAP, subscription, iPhone, Mac, TV, Watch, Vision.

**Start with [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).**
For an existing app, follow [`docs/INTEGRATION.md`](docs/INTEGRATION.md): deploying Keel needs
an app-owned CDK project and a pinned Keel server checkout as well as the Swift dependency.

## What Keel does

Keel gives your app a backend with six capabilities, all opt-in, that work from the first
launch and cost cents at small scale.

**Remote configuration.** Change feature flags, URLs, and arbitrary app-specific payloads
without an App Store release. The client resolves network → disk cache → compiled-in
default, so a backend outage is invisible to the user.

**Feature flags.** Boolean flags with compiled-in defaults, overridable from the server.
Fail-open by design: an unreachable backend never removes a feature the app already ships.

**Version gate.** Block unsupported builds (full-screen dead end), nudge old builds to
update (dismissible banner), or show a maintenance notice — all driven by a single remote
config value, no app update needed.

**Anonymous telemetry.** Installs, DAU, MAU, conversion counts, plus version, OS, and
platform distributions — all without any device identifier. Deduplication happens on the
device; the server only increments shared counters. Everything collected is published at
`/v1/stats` and rendered by a dashboard.

**Custom dimensions.** App-specific distributions (e.g. "how many profiles does a user
have?") sent as pre-bucketed values so the raw number never leaves the device.

**App Store verification (optional).** Server-side StoreKit 2 JWS verification and App Store
Server Notifications v2 verification (refunds, revocations, expirations) via the `KeelAppStore`
module — verification only, no entitlement model: what a purchase grants is the app's business.
The client-side `EntitlementService` bridges StoreKit into the `LicenseState` the rest of the
framework speaks.

All of this deploys as **one Lambda, one DynamoDB table, and one HTTP API**, behind a
domain you own. The CDK construct library handles the infrastructure; you bring a
`KeelConfiguration` on the client and a CDK stack on the server.

→ **[Integration Guide](docs/INTEGRATION.md)** — step-by-step adoption: client SDK,
server-side CLI, backend deployment, dashboard, and App Store verification.
→ **[Architecture Guide](docs/ARCHITECTURE.md)** — the design behind each piece: data
model, request flows, privacy model, infrastructure, cost model.

## What you get

| Artifact | Path | Consume as |
|---|---|---|
| Client library | `Package.swift` | SPM: `KeelCore`, `KeelClient`, `KeelClientSigning`, `KeelClientTesting` |
| Server library + Lambdas | `server/Package.swift` | SPM: `KeelServer`, `KeelServerDynamoDB`, `KeelServerTesting`; executables `KeelLambda`, `KeelAuthorizerLambda`, `keel` |
| Infrastructure | `cdk/` | npm: `@keel/cdk` → `KeelBackend`, `KeelAuth`, `KeelStatsSite` |
| Stats dashboard | `dashboard/` | static files, deployed by `KeelStatsSite` |
| Reference app | `Templates/SampleApp/` | copy, or `keel new` |

## Adopting it

**Backend** — instantiate one construct:

```ts
const backend = new KeelBackend(this, "Backend", {
  appName: "myapp",
  envName: "prod",
  auth: KeelAuth.sharedSecret({ parameterName: "/myapp/api-token" }),
  publicRoutes: ["/v1/stats"],
  domain: { domainName: "api.myapp.com", certificate },
  budgetEmail: "me@example.com",
});
new KeelStatsSite(this, "Stats", { api: backend.httpApi, domainName: "myapp.com" });
```

Use a domain you own from the first release — the base URL is compiled into shipped clients
and is the one thing bootstrap can't fix later (`docs/adr/0007-stable-base-url.md`).

**Client** — one configuration value and two view modifiers:

```swift
@main struct MyApp: App {
    @State private var config = RemoteConfigStore<MyAppConfig>(
        keel: KeelConfiguration(baseURL: .myBackend, auth: .sharedSecret(.fromKeychain)),
        default: .compiledIn
    )

    var body: some Scene {
        WindowGroup {
            RootView()
                .keelBootstrap(config)      // fetch config + flags, publish as they resolve
                .keelVersionGate(config)    // blocking update / soft banner / maintenance
                .task { await TelemetryService.shared.run(licenseState: license.state) }
        }
    }
}
```

Nothing above is on the critical path: bootstrap falls back network ▸ disk cache ▸
compiled-in default, and telemetry is fire-and-forget with a 3-second budget. A backend
outage is invisible to the user.

## Privacy

Telemetry carries **no identifier of any kind**, and no code path derives one.
Deduplication happens on the device; the server only ever increments a shared counter.
Nothing is logged — not the body, not the IP, not the User-Agent. Everything collected is
published at `/v1/stats`.

This is structural, not a policy: `docs/ARCHITECTURE.md` §9 lists the eight claims and the
mechanism behind each, `docs/adr/0004-client-side-dedup-no-identifier.md` records what it
costs (retention cohorts are impossible; reinstalls count twice), and `docs/PRIVACY.md` is a
policy template whose claims the code keeps true.

## Working on Keel

```
make test        # swift test in both packages + npm test in cdk/
make build       # client, server, and the arm64-musl Lambda build
make lint        # swift-format lint + eslint
make local       # run KeelLambda locally (in-memory store); POST events to :7000/invoke
make smoke       # invoke bootstrap/ping/stats against a running `make local`
make docs        # verify the mermaid diagrams in docs/ parse
```

Requires Swift 6.2+ (Xcode 26+), Node 20+, and Apple's
[container](https://github.com/apple/container) CLI (or Docker) for Lambda builds.

## Status

All eight phases implemented and green: wire contract with golden fixtures, server
handlers, DynamoDB stores and Lambda executables, the `@keel/cdk` constructs, the client
library, the dashboard, the App Store verification layer, and the SampleApp template
(`scripts/keel-new.sh MyApp` scaffolds a new app from it). Remaining before first real
use: deploy `Templates/SampleApp` to an AWS account end-to-end, and the per-app retrofit
plans sketched in `docs/RETROFIT.md`.

## Layout

```
Package.swift              client package (Apple + Skip-safe core)
  Sources/KeelCore/        portable: wire types, transport, pure decisions — read its README
  Sources/KeelClient/      Apple: @Observable stores, SwiftUI, StoreKit
  Sources/KeelClientSigning/ Apple: reference KeelSigV4Transport for KeelAuth.iam()
  Sources/KeelClientTesting/
server/Package.swift       server package (Linux + macOS)
  Sources/KeelServer/      wire types, CounterSchema, handlers, store protocols
  Sources/KeelServerDynamoDB/
  Sources/KeelLambda/      the ready-made function
  Sources/KeelAppStore/    App Store JWS + notification verification (optional)
  Sources/keel-cli/        config get/set, stats dump
cdk/                       @keel/cdk construct library
dashboard/                 static stats site
Templates/SampleApp/       end-to-end reference
docs/                      ARCHITECTURE.md, PRIVACY.md, RETROFIT.md, adr/
```

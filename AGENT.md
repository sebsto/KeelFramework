# AGENT.md — using Keel from an AI coding agent

Instructions for an AI agent adopting **Keel** in an app, or migrating an existing app
onto it. Keel gives an app three things without an App Store release in the loop:
remote config + feature flags + a version gate (`/v1/bootstrap`), anonymous usage
counters with a public stats page (`/v1/ping`, `/v1/stats`), and optionally App Store
entitlements (`/v1/purchase`, `/v1/entitlement`, `/v1/appstore-notification`).

Authoritative references, in the order to consult them:

| Question | Read |
|---|---|
| How does it work / why is it shaped this way | `docs/ARCHITECTURE.md` |
| What may I promise about privacy | `docs/PRIVACY.md` (the code is built to keep it true) |
| Complete working example | `Templates/SampleApp/` |
| Migrating a specific existing app | `docs/RETROFIT.md`, then §Migration below |
| Manual verification | `docs/TEST-PLAN.md` |
| Past decisions and their reasons | `docs/adr/` |

## The three artifacts

| Artifact | Where | An app depends on |
|---|---|---|
| Client SPM package | repo root `Package.swift` | `KeelClient` (Apple) and/or `KeelCore` (portable/Skip) |
| Server SPM package | `server/Package.swift` | usually nothing — deploy `KeelLambda` as-is; apps with their own routes depend on `KeelServer` + `KeelRouter` |
| CDK constructs | `cdk/` (`@keel/cdk`) | `KeelBackend`, `KeelAuth`, `KeelStatsSite` |

Plus `dashboard/` (static stats page, restyled via `tokens.css` only) and
`Templates/SampleApp` (`scripts/keel-new.sh MyApp` copies and renames it).

---

## Invariants — do not violate these

These are load-bearing design properties. Code that breaks one will be rejected even if
it works.

1. **Never add an identifier to telemetry.** No device id, user id, hash, or salt on the
   ping path — no *field that could carry one*. Adding one is a privacy-policy change
   first (`docs/ARCHITECTURE.md` §9) and requires the human's explicit decision.
2. **Flags fail open.** A missing config, unreachable backend, or unknown flag reads as
   the compiled-in default. Never make a shipped feature depend on the network saying yes.
3. **The user's telemetry opt-out beats everything**, including the server's
   `telemetry.enabled`. The server switch can only turn collection *off*.
4. **Wire types are duplicated on purpose** in `Sources/KeelCore/Wire/`,
   `server/Sources/KeelServer/Wire/`, and `cdk/lib/contract.ts`. A wire change touches
   all copies **and** the golden fixtures in `Fixtures/`; the fixture tests in both
   packages are what keep the copies equal. Do not "deduplicate" them into a shared
   target — the client must not resolve NIO/soto and the server must not resolve Skip.
5. **`server/Sources/Soto/` is generated.** Never edit it; rerun
   `scripts/generate-soto.sh` (see `docs/adr/0006-codegen-soto.md`). It builds with
   relaxed settings and is excluded from lint.
6. **One table, no GSI, no Scan.** Every read is a `Query`/`GetItem` on a key
   `CounterSchema` (or `EntitlementSchema`) builds. If a feature seems to need a GSI,
   the schema is wrong — put the stamp in the right half of the key instead (§4).
7. **Validation rejects, never truncates.** Client strings that become DynamoDB keys are
   bounded; a limit violation is a 400 naming the field and rule, **never echoing the
   value**. Request bodies, IPs, and User-Agents are never logged.
8. **Keys are backward-compatible.** `AGG#…` names and stamp formats match what Orthanc
   and odvpn already store. Renaming one orphans history; prefer an awkward name.
9. **Strict build settings stay on.** Both packages use `treatAllWarnings(as: .error)`,
   `ExistentialAny`, `MemberImportVisibility`, `InternalImportsByDefault`,
   `NonisolatedNonsendingByDefault`. `KeelCore` must additionally stay Skip-safe — read
   `Sources/KeelCore/README.md` before touching it (no Observation, no `os.Logger`, no
   `Calendar`, no macros). Server code must compile with `FoundationEssentials` on musl:
   no `CharacterSet`, `FileHandle`, `replacingOccurrences`, `ISO8601DateFormatter`.
10. **Every counter the table gains must appear in `/v1/stats`.** Publishing everything
    is the mechanism that makes the privacy claim auditable, and a test enforces it.

Every change must end green: `make test && make lint`, and
`swift build --package-path server --swift-sdk <static-linux-sdk>` for server changes.

---

## Using Keel in a new app

Fastest path: `scripts/keel-new.sh MyApp`, then follow the generated `README.md`. The
manual equivalent, for wiring into an existing project structure:

### Backend (TypeScript CDK)

```ts
import { KeelAuth, KeelBackend, KeelStatsSite } from "@keel/cdk";

const backend = new KeelBackend(this, "Backend", {
  appName: "myapp",
  envName: "dev",                      // "prod" flips the table to RETAIN + PITR
  auth: KeelAuth.none(),               // or sharedSecret / iam / jwt — see below
  lambdaPackagePath: "path/to/keel/server",
  // aliasRoutes, domain, iap, budgetEmail, reservedConcurrency: see KeelBackendProps
});
new KeelStatsSite(this, "Stats", { api: backend.httpApi });
```

- Build the function first: `make lambda` at the Keel repo root. Before that, synth
  still works against a placeholder.
- `auth`: `sharedSecret` needs an SSM SecureString created out-of-band
  (`aws ssm put-parameter --type SecureString …`); `iam`/`jwt` need no Lambda at all.
  `/v1/stats` is public by default; adjust with `publicRoutes`.
- **Before the first public release**, set `domain` — the base URL is compiled into
  shipped clients and the generated hostname dies with the resource
  (`docs/adr/0007-stable-base-url.md`). Prod-without-domain synths with a warning.
- The stack outputs `ApiBaseUrl` (goes into the client) and `TableName` (goes into
  `keel` CLI commands).

An app with its own server routes does **not** fork `KeelLambda`: it writes its own
executable that depends on `KeelServer` + `KeelRouter` (+ `KeelIAPRouter` if selling),
calls `builder.mount(keel:)`, and registers its own routes on the same builder.
`server/Sources/KeelLambda/Lambda.swift` is the reference for the wiring.

### Client (Swift)

Wire order matters; copy `Templates/SampleApp/App/SampleApp.swift`:

1. Declare the flag vocabulary — an enum conforming to `KeelFlag`. `defaultValue` is a
   required member, so a flag without a compiled-in default does not compile.
2. Build **one** `KeelConfiguration` in `@main` (it is `@MainActor` because platform
   detection reads `UIDevice`). Only `baseURL` is required.
3. `RemoteConfigStore<AppPayload>` — call `bootstrap()` from the root `.task`. It
   publishes the disk cache immediately, then refreshes; the UI observes `response`.
   `AppPayload` is the app's own remote config type; use `Empty` if there is none.
4. `.keelVersionGate(config.gateDecision)` at the **root, outside navigation** — a
   blocked build must not be navigable around.
5. `TelemetryService(configuration:).run(licenseState:telemetry: config.telemetry)` from
   the same `.task`. It reads the *cached* config, so it has no ordering dependency on
   the fetch. Second launch of a UTC day sends nothing at all.
6. Settings screen: `TelemetryToggle()` with `TelemetryToggle.footer`.
7. Selling something? `EntitlementService(paidProducts:)`, `.task { await es.start() }`,
   and feed `es.licenseState` into the ping. Server side, add `iap:` to `KeelBackend`
   and point App Store Connect's server-notification URL at `/v1/appstore-notification`.

App-specific distributions (e.g. "how many profiles") are **bucketed on the device**:
pass `dimensions: ["profiles": "3-5"]` to `run`, and declare the allowlist server-side
(`keel config set`, `telemetry.dimensions`). Raw counts must never leave the device;
there is deliberately no zero bucket.

### Operating it

```sh
keel config get  --table <TableName>
keel config set  features.confetti true --table <TableName>     # live ≤ 60 s
keel config set  telemetry.enabled false --table <TableName>    # kill switch, both sides
keel config set  gate.minSupportedVersion 2.0 --table <TableName>
keel config replace --file config.json --table <TableName>
keel stats dump  --table <TableName>
```

Emergency flag override without the table: set `FEATURE_FLAGS="a=true,b=0"` on the
function. Alias routes are deployment config: `ALIAS_ROUTES="/station=bootstrap.flattened"`
(set via the CDK `aliasRoutes` prop, not by hand).

---

## Migrating an existing app onto Keel

Read `docs/RETROFIT.md` first — it has per-app notes for Maxi80, Orthanc, and odvpn.
This is the generic procedure. **The table schema is byte-compatible with existing
`AGG#` data by design: no migration step may copy, rewrite, or delete counter items.**

### Step 0 — inventory (produce this before changing anything)

Grep the app and its backend for, and write down:

- [ ] Bootstrap/config endpoint: path, response shape, which fields are app-specific
- [ ] Feature-flag mechanism: names, defaults, where they're read
- [ ] Telemetry: endpoint, payload fields, the `UserDefaults` keys holding dedup state
      and the opt-out (exact key strings — you will migrate them)
- [ ] Version-gate / kill-switch logic, if any
- [ ] Counter table: name, key formats, whether it matches `AGG#` (see `CounterSchema`)
- [ ] Auth: how requests are authorized today
- [ ] Server routes that are NOT Keel's concern (these stay in the app's own executable)
- [ ] IAP/receipt verification, if server-side

### Step 1 — backend swap

1. Deploy `KeelBackend` **pointed at the existing table** (import it; do not let the
   construct create a new one) — or a fresh table if history is dispensable.
2. Declare every legacy path as an alias:
   `aliasRoutes: { "/station": { route: "/v1/bootstrap", envelope: "flattened" } }`.
   `flattened` reproduces a legacy response whose app payload sat at the top level; it
   is only valid on bootstrap. Shipped clients must keep working unchanged — verify
   with a curl of the old path comparing against the old backend's response.
3. If the app has its own routes, write the thin executable around `mount(keel:)` and
   move them there; retire the bespoke Lambda after.
4. Move flags/gate/URLs/app-payload into the config item:
   `keel config replace --file config.json`. Diff `GET /v1/bootstrap` (and the alias)
   against the old endpoint's output field by field.

### Step 2 — client swap

1. Replace the bespoke config fetch with `RemoteConfigStore<TheirPayloadType>` — the
   old response's app-specific struct becomes the `App` type parameter, usually
   field-for-field unchanged.
2. Replace the flag mechanism with a `KeelFlag` enum carrying the same names and the
   same defaults. Same *wire names* — the server keeps no flag list, so a renamed flag
   silently reverts to its default.
3. Replace the telemetry client with `TelemetryService`.
4. **Migrate the `UserDefaults` state — this is the step that gets forgotten.** Keel
   reads its own keys (`TelemetryService.Key.*`). Copy the old values once, *before*
   the first `run(...)`:

   ```swift
   let defaults = UserDefaults.standard
   if defaults.object(forKey: TelemetryService.Key.lastPingDate) == nil {
       if let d = defaults.object(forKey: "<old lastPingDate key>") as? Date {
           defaults.set(d, forKey: TelemetryService.Key.lastPingDate)
       }
       if let v = defaults.string(forKey: "<old lastPingVersion key>") {
           defaults.set(v, forKey: TelemetryService.Key.lastPingVersion)
       }
       if defaults.object(forKey: "<old hasPingedPaid key>") as? Bool == true {
           defaults.set(true, forKey: TelemetryService.Key.hasPingedPaid)
       }
       if let enabled = defaults.object(forKey: "<old opt-out key>") as? Bool {
           defaults.set(enabled, forKey: TelemetryService.Key.isEnabled)
       }
   }
   ```

   Consequences of skipping each: `lastPingDate` → every migrated install re-fires
   `firstPingEver` and inflates installs; `hasPingedPaid` → double-counted conversions;
   **the opt-out → telemetry silently re-enabled for users who declined, which breaks a
   published promise. That one is not optional.**
5. Keep the old keys' semantics in mind: if the old opt-out stored "true = disabled",
   invert it when copying (Keel's `isEnabled` is "true = enabled").

### Step 3 — semantic deltas to flag to the human

Keel deliberately changes some counting behavior. Do not "fix" these back; do call them
out in the migration PR:

- **OS/platform/dimension spreads dedup monthly**, not daily. `sum(osVersions)` becomes
  ≈ MAU from cutover (odvpn's old daily counting is the bug, not the baseline).
- **Version spread is monthly census + on-upgrade**, so `sum(versions)` may exceed MAU.
- **Dedup state persists only after an accepted send** — a failed ping retries next
  launch instead of silently dropping a day.
- Vocabulary renames (e.g. Orthanc's `licenseState: "full"` → `paid`) start new cohort
  partitions at cutover; the chart has a visible seam at the migration date. Accepting
  the seam is the default; do not write server-side compatibility shims.

### Step 4 — verify

- Old shipped client against the new backend: alias path returns the legacy shape,
  byte-relevant fields identical.
- New client, migrated install: first launch after update sends **no** `firstPingEver`.
- `keel stats dump` before/after: historical numbers unchanged (same table, same keys).
- Opt-out users: still opted out (check the copied key).
- Run the relevant sections of `docs/TEST-PLAN.md` (§4–§7).

---

## Things agents get wrong here — quick table

| Temptation | Why it's wrong | Instead |
|---|---|---|
| Add a device hash "just for dedup" | Invariant 1; breaks the published policy | client-side `first*` booleans already dedup |
| Merge the duplicated wire types | couples client to NIO / server to Skip | change all copies + fixtures |
| `grantReadWriteData` on the table | grants Scan/Delete nothing uses | the explicit 3–4 action grant in `KeelBackend` |
| Truncate an over-long client string | silently merges counters | 400 via the existing validators |
| Return an error from the ping on store failure | teaches clients to retry a non-idempotent write | log and return `{"ok":true}` (existing behavior) |
| Cache a config read failure | outage sticks for a TTL | `ConfigCache` already retries next call — keep it |
| Zero-fill unobserved dimension buckets | "unmeasured" is not "zero" | only days/months zero-fill |
| Edit `server/Sources/Soto/**` | generated | `scripts/generate-soto.sh` |
| A fixed `tableName` in dev | orphan-table trap on replacement | let CloudFormation name it |
| `swift package plugin lambda-build` | breaks with >1 static SDK installed | `make lambda` (packages by hand) |

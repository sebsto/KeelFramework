# Retrofitting the three existing apps onto Keel

Keel's table schema is byte-compatible with what Orthanc and odvpn already write — that
was a design constraint, not luck (`CounterSchema`'s doc comment) — so **no retrofit
involves a data migration**. Point the Keel handlers at the existing table and the
history is intact. Each app gets its own plan when its retrofit actually happens; this
document records what those plans will have to deal with, while the details are fresh.

## The common shape

Every retrofit is the same four moves:

1. **Backend**: replace the bespoke Lambda with `KeelLambda` (or a thin executable
   around `builder.mount(keel:)` if the app has routes of its own), deployed by
   `KeelBackend` pointed at the *existing* table via imports — or a new table if the
   history is dispensable.
2. **Config**: run `keel config replace --file config.json` to move the app's flags,
   gate, and URLs into the `CONFIG#current` item.
3. **Client**: swap the bespoke bootstrap/telemetry code for `RemoteConfigStore`,
   `FeatureFlags`, and `TelemetryService`; migrate the `UserDefaults` dedup keys (below).
4. **Aliases**: declare the old paths in `aliasRoutes` so shipped clients keep working
   for as long as they exist in the wild.

### Migrating the telemetry dedup keys

Keel reads its own key names (`keel.telemetry.*`). A shipped install has state under the
app's old names, and losing it re-fires `firstPingEver` — every migrated install counts
as a new install. Each app's retrofit must copy the old values once, before the first
`TelemetryService.run`:

```swift
let defaults = UserDefaults.standard
if defaults.object(forKey: TelemetryService.Key.lastPingDate) == nil,
   let old = defaults.object(forKey: "lastPingDate") as? Date {
    defaults.set(old, forKey: TelemetryService.Key.lastPingDate)
    // …and lastPingVersion, hasPingedPaid, and the opt-out, under their old names.
}
```

The opt-out key matters most: failing to migrate it re-enables telemetry for users who
turned it off, which is the one migration bug that breaks a published promise.

## Maxi80

| Existing | Keel |
|---|---|
| `GET /station` → `Station` fields + `features` at the top level | `aliasRoutes: { "/station": { route: "/v1/bootstrap", envelope: "flattened" } }` |
| `FEATURE_FLAGS` env override | identical — `FeatureFlagsOverride` is Maxi80's parser, kept |
| SAM `template.yaml` | `KeelBackend` (the artwork/history routes stay in Maxi80's own executable via `mount(keel:)`) |
| no telemetry | free: adopt `TelemetryService`, get the dashboard |

The flattened alias is the whole trick: shipped players keep decoding `/station` while
new builds move to `/v1/bootstrap` with the station payload under `app`. The `Station`
struct becomes the `App` type parameter of `RemoteConfigStore<Station>` — field-for-field
unchanged. Maxi80's Android build (Skip) uses `KeelCore` only: wire types, transport,
`PingFlags`; the Observation layer stays Apple-side.

Watch for: the `/artwork` and `/history` routes need Maxi80's S3 code, so Maxi80 keeps
its own Lambda executable mounting Keel's router beside its own — the reference for
"an app with routes of its own".

## Orthanc

| Existing | Keel |
|---|---|
| `AGG#` counter table | **identical keys** — point Keel at it, zero migration |
| `licenseState: "full"` | Keel says `paid`; the old `AGG#DAU#full` partitions keep their name |
| `profileBuckets` in `/v1/stats` | `dimensions: { "profiles": [...] }` |
| `ProfileBucket` client enum | a `dimensions: ["profiles": bucket.rawValue]` entry + config allowlist `["1-2","3-5","6-10","11+"]` |

The `full` → `paid` rename is the one real decision. The old partitions
(`AGG#DAU#full/…`) stay readable but Keel writes `AGG#DAU#paid/…` from the cutover day,
so the paid cohort chart has a seam at the migration date. The retrofit plan chooses:
accept the seam (recommended — it is one visible day), or have the dashboard's fetch
merge `full` into `paid` client-side for the overlap window. Keel's server will not
special-case it.

Orthanc's stats page is replaced by `dashboard/` with its `tokens.css` set to Orthanc's
brand tokens — the renderer *is* Orthanc's, merged with odvpn's.

**Profile-spread partition rename:** Keel changed the storage key for profile spreads
from `AGG#PROFILES#2026-08` to `AGG#DIM#profiles#2026-08`. This means `StatsHandler`
will not see historical profile data even though the headline says "history survives"
(the counter keys themselves are untouched, but the profile-spread series sits under a
different prefix). The fix is a one-time copy — roughly four items per month — or adding
a name alias in `StatsHandler` that reads both keys and merges results. The copy is
simpler; the alias survives future key renames more gracefully.

**Orthanc does not mount `KeelIAP`.** Orthanc's purchase flow runs entirely on-device
(StoreKit receipt validation + Ed25519 server signature), and the published privacy
statement says the table holds no per-device row. Mounting `KeelIAP` would add exactly
that row, falsifying the privacy claim. Orthanc keeps its own `LicenseHandlers` and
`VPNBilling` is not applicable here — the distinction matters because `KeelIAP` is
designed for entitlement tracking, not for Orthanc's signature-and-forget model.

## odvpn

| Existing | Keel |
|---|---|
| `AGG#` schema in `StatsStore.swift` | identical — same zero-migration story |
| OS spread incremented on `firstToday` | Keel dedups it monthly; `sum(osVersions)` becomes ≈ MAU from cutover (documented behavior change, deliberate) |
| `StatsClient` persisting dedup before send | Keel persists only after an accepted send — silently fixes the dropped-day bug |
| IAM auth via Cognito | `KeelAuth.iam()`; the SigV4-signing transport stays odvpn's own `HTTPTransport` conformance |
| purchase/credits/billing stack | **not** Keel's — `KeelIAP` covers entitlements, not credit metering; odvpn keeps `VPNBilling` and mounts Keel beside it |

odvpn is the "large app adopts the telemetry/bootstrap slice only" case: its eleven
stacks keep their jobs, `KeelBackend` replaces just the stats table + ping/stats routes,
and its `usage.js` page is retired for `dashboard/`.

**odvpn does not mount `KeelIAP` either.** Its purchase model is credit-based (buy
blocks of credits, deduct on each VPN session), which has no mapping onto `KeelIAP`'s
boolean entitlement model. `VPNBilling` stays as-is; Keel covers only the
bootstrap/telemetry/stats slice.

## What no retrofit needs

- A table migration or backfill. The keys match by construction.
- Coordinated deploys for Maxi80, which has shipped clients in the wild. The backend
  can move to Keel while old clients still call the legacy path, because aliases remap
  to the right route and the flattened envelope reproduces the old response shape.

**However, Orthanc and odvpn are both pre-release: neither has shipped a client, neither
has users.** Their retrofits are the clean case — the client and backend can ship
together in a single coordinated update, with no aliases needed. The ping body is not
backward-compatible across the Keel boundary (Keel requires closed enum values for
`platform` and `licenseState`, and sends a single `profileBucket` dimension rather than
the old `dimensions` map), so a mixed deploy — new backend, old client, or vice versa —
would break. The solution is simple: don't do a mixed deploy.

A per-deployment opt-in compatibility shim is possible in principle (translate old enum
values server-side, accept both body shapes), but there is no reason to build one for
these two apps. If Maxi80 ever needs it, that decision belongs to its retrofit PR.

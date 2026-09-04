# Retrofitting an existing app onto Keel

Keel's table schema is byte-compatible with the aggregate-counter shape a hand-written
telemetry backend typically arrives at — that was a design constraint, not luck
(`CounterSchema`'s doc comment) — so **a retrofit needs no data migration**. Point the Keel
handlers at the existing table and the history is intact.

This is the generic guide. An individual app's retrofit plan, with its own decisions and
sequencing, belongs in that app's repository, not here.

## The common shape

Every retrofit is the same four moves:

1. **Backend**: replace the bespoke Lambda with `KeelLambda` — or a thin executable around
   `builder.mount(keel:)` if the app has routes of its own — deployed by `KeelBackend`
   pointed at the *existing* table via `existingTable`, or at a new table if the history is
   dispensable.
2. **Config**: run `keel config replace --file config.json` to move the app's flags, gate,
   and URLs into the `CONFIG#current` item.
3. **Client**: swap the bespoke bootstrap/telemetry code for `RemoteConfigStore`,
   `FeatureFlags`, and `TelemetryService`; migrate the `UserDefaults` dedup keys (below).
4. **Aliases**: declare the old paths in `aliasRoutes` so shipped clients keep working for
   as long as they exist in the wild.

### Migrating the telemetry dedup keys

Keel reads its own key names (`keel.telemetry.*`). A shipped install has state under the
app's old names, and losing it re-fires `firstPingEver` — every migrated install counts as a
new install. Copy the old values once, before the first `TelemetryService.run`:

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

**An app with no shipped clients should skip this entirely** and adopt Keel's key names
directly. The migration is the riskiest ten lines in a retrofit, and a pre-release app does
not need to write them.

## Cases you are likely to hit

**The app has routes of its own.** Keep them: write your own Lambda executable that calls
`builder.mount(keel:)` and registers your routes on the same builder, point `KeelBackend` at
it with `lambdaAssetPath`, and declare your paths in `appRoutes` so the gateway routes them
(with their CORS preflight). See Part 3 of [INTEGRATION.md](INTEGRATION.md).

**The app already serves a bootstrap-shaped endpoint.** Declare it in `aliasRoutes`. With
`envelope: "flattened"` the `app` payload's keys are emitted at the top level beside
`features`, which reproduces the common "config fields inline" response shape, so shipped
clients keep decoding the old path while new builds move to `/v1/bootstrap`. Your existing
config struct becomes the `App` type parameter of `RemoteConfigStore<App>`, usually
field-for-field unchanged.

**The app renames a cohort value.** If the app's wire vocabulary differs from Keel's — say
`licenseState: "full"` where Keel says `paid` — the old partitions stay readable under their
old names, but Keel writes the new name from the cutover day, so that cohort's chart has a
seam at the migration date. Two options: accept the seam, which is one visible day, or have
the dashboard merge the two client-side for the overlap window. The server will not
special-case it.

**The app has a per-dimension counter key.** Keel stores dimension spreads under
`AGG#DIM#<name>#<month>`. An app that used a bespoke prefix such as `AGG#PROFILES#<month>`
will not see its historical series until it either copies those items once — a handful per
month — or configures the legacy dimension name verbatim so Keel keeps writing it.

**The app's purchase flow runs on-device.** Mount nothing from `KeelAppStore`. It verifies
Apple's paperwork and stores nothing, so it cannot falsify a "no per-device row" privacy
claim — but an app that unlocks local UI gains nothing from a server check either, since no
server check helps against a patched client. Keep your own licensing code.

**The app's purchase model is not an entitlement.** Credit balances, ledgers, consumption
reporting and refund reversal are not modelled by the framework, and `KeelAppStore` is
verification-only, so there is nothing to map onto or reject. Keep your billing stack and
reuse the verifier beside it if it helps: that is code reuse, not a data model you have to
adopt.

## Behaviour changes to expect

Two things a bespoke implementation commonly does differently, which Keel changes
deliberately:

- **OS, platform and dimension spreads dedup monthly, not daily.** If the app incremented
  them on `firstToday`, `sum(osVersions)` was a sum of daily actives; after the cutover it
  becomes ≈ MAU. The monthly figure is the correct one.
- **Dedup state is persisted only after an accepted send.** An implementation that persists
  first silently drops a day whenever a ping fails. Keel does not, so a rejected ping leaves
  the day unconsumed.

## What no retrofit needs

- A table migration or backfill. The keys match by construction.
- Coordinated client and backend deploys, *if* the app has shipped clients. The backend can
  move to Keel while old clients still call the legacy path, because aliases remap to the
  right route and the flattened envelope reproduces the old response shape.

**A pre-release app is the clean case.** With no shipped client, the client and backend ship
together in one update and no aliases are needed. Note that the ping body is *not*
backward-compatible across the Keel boundary — Keel requires closed enum values for
`platform` and `licenseState`, and takes a `dimensions` map rather than any bespoke
single-bucket field — so a mixed deploy of a new backend with an old client, or the reverse,
would break. The solution is not to do a mixed deploy.

A per-deployment compatibility shim is possible in principle (translate old enum values
server-side, accept both body shapes). Nothing in the framework provides one, and an app that
needs it should decide that in its own retrofit.

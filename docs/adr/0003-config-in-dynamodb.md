# 0003 — Remote config lives in DynamoDB, not SSM, S3, or environment variables

**Status:** accepted · 2026-08-24

## Context

`/v1/bootstrap` serves feature flags, the version gate, URLs, and an app-specific payload.
Something has to store them, and the kill switch in particular has to be changeable in
seconds without a deployment.

The common answers are a `FEATURE_FLAGS` environment variable parsed at cold start, which
needs a deployment to change, or no config service at all.

| Option | Change latency | Reads | Notes |
|---|---|---|---|
| Environment variable | `update-function-configuration`, then a cold start | free | can't hold structured JSON; flips only after the environment recycles |
| SSM Parameter Store | instant | throttled at 40 TPS (or 10k/s paid); another IAM grant, another service | advanced parameters cost per-parameter |
| S3 object | instant | cheap, but another bucket, another grant, another failure mode | no atomic multi-key update |
| **DynamoDB item in the existing table** | instant | one `GetItem` per cache miss | table, client, and IAM grant already exist |

## Decision

`CONFIG#current` / `v1` in the same table, holding the config as a JSON string in a
`payload` attribute.

- Served through `ConfigCache`, an `actor` with a 60-second TTL, so a warm function reads
  DynamoDB at most once a minute regardless of traffic.
- On a read failure the cache **serves the last known good value**, however stale. An
  unreachable table must not make `/v1/bootstrap` fail — a failed bootstrap is a client
  falling back to compiled-in defaults, which may re-enable something the flag was
  switched off to stop.
- `Cache-Control: public, max-age=60` on the response, matching the server cache, so the
  worst-case propagation for a kill switch is ~2 minutes end to end.
- The compiled-in default in the client is the third tier and the real floor: the app works
  with no server at all.

Deployment-time settings (`tableName`, `configTTLSeconds`, window sizes, alias routes) are
*not* here. They go through `swift-configuration`'s `ConfigReader` (env ▸ bundled JSON),
because they change only when the stack changes.

## The one exception

`FEATURE_FLAGS="a=true,b=1"` as an environment variable still works, layered *over* the
table. It exists for the case where the table is unreachable or a flag
must be flipped faster than a `keel config set` round-trip. Malformed entries are dropped
and logged rather than fatal — a typo in an emergency override must never take
`/v1/bootstrap` down, which is the failure mode it exists to prevent.

## Consequences

**Good.** No new service, no new IAM grant, no new failure mode. Config and counters share
one backup and one PITR window. `keel config get/set` is a two-call CLI.

**Bad.** Config is inside a table whose deletion protection matters more than a config
store's normally would. There is no version history — a bad `config set` overwrites the
previous value, so `keel config set` prints the old payload before writing it, and that is
the whole audit trail. If that becomes insufficient, add `CONFIG#current` / `v<n>` items
rather than reaching for another service.

# 0001 — One DynamoDB table, one Lambda, `AGG#` counter items

**Status:** accepted · 2026-08-24

## Context

Several apps needed the same anonymous counters, and independent implementations converged on
the same schema: one table, `pk`/`sk`, partitions prefixed `AGG#`, values incremented with
`UpdateItem ADD`. Where an implementation also spread its backend across many CDK stacks and
several functions, that fan-out was the part that proved hard to live with.

The alternatives considered were a time-series store (Timestream), per-event items
aggregated later by a scheduled job, and a relational store.

## Decision

One table, one function.

- `pk` = `AGG#<metric>[#<qualifier>]`, `sk` = the bucket (`2026-08-24`, `2.1.0`, `ios`, …),
  one numeric attribute `count`, TTL attribute `ttl`.
- Every write is a single `UpdateItem` with `ADD #count :one` — an upsert, atomic across
  any number of concurrent devices, no read-modify-write, no condition expression.
- Every read is a `Query` on one partition. **No GSI. No `Scan`.**
- On-demand billing. Dated partitions expire after 400 days; totals never.

## Consequences

**Good.** Writes cannot contend or lose updates, so a device does not need to be
identified for the count to be right. Reads are bounded and predictable, which is what
lets `/v1/stats` be a public endpoint. Nothing needs a scheduled aggregation job, so there
is no window in which the published numbers are stale for reasons other than the cache.
Cost is cents at 10k MAU (`ARCHITECTURE.md` §11).

**Bad.** The queries are fixed at write time: the table answers exactly the questions the
key design anticipated and no others. There is no way to ask "how many devices ran 2.1.0
*and* were paid" unless a partition was written for that pair. Adding a new dimension only
starts collecting from the day it ships — history cannot be recomputed, because the events
were never stored. That is the price of storing no events, and it is the same price that
buys the no-identifier property (ADR 0004): there is nothing to re-aggregate because there
is nothing per-device to re-aggregate.

**Compatibility.** The keys match that converged schema byte for byte, so an app already
writing it can be retrofitted by pointing Keel at its existing table. The one shape that
moves is a per-dimension key such as `AGG#PROFILES#<month>` → `AGG#DIM#profiles#<month>`,
and a legacy dimension name can be configured verbatim to avoid even that.

## Notes

`400` days, not 365: a year-over-year comparison needs slightly more than a year of
history, and the extra five weeks cost nothing.

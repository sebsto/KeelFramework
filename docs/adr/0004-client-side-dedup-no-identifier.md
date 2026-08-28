# 0004 — Deduplication happens on the client; no identifier exists

**Status:** accepted · load-bearing · 2026-08-24

## Context

Daily and monthly active counts require knowing whether a launch is the first one today for
*this* device. The conventional answer is to send an identifier and let the server
deduplicate — an install id, an IDFV, a hashed machine id, even a salted one.

Orthanc started there. It had a hashed machine identifier and a salt, to make a 30-day
trial unresettable. When the trial was dropped, both were **deleted rather than left
dormant**, and its published policy now states flatly that no identifier and no salt exist
in the binary. That turned out to be the most valuable property of the whole design, and it
is the one this framework is built to preserve.

## Decision

The device decides. The ping carries five booleans — `firstPingEver`, `firstToday`,
`firstThisMonth`, `firstThisVersion`, `firstPaidLaunch` — computed by
`PingFlags.compute(...)`, a pure function over `UserDefaults` state and a UTC clock. The
server trusts them and only ever issues `UpdateItem ADD`.

The invariant, stated so it can be checked:

1. No request field can carry an identifier.
2. No code path derives one — no hashing on the telemetry path, and `KeelCore` does not
   import `CryptoKit`.
3. No table item is keyed by anything device-specific.
4. Where the transport is authenticated (`iam` mode), the handler never reads the caller
   identity and never writes it anywhere.
5. Nothing is logged: no body, no headers, no IP, no User-Agent. Errors name the type that
   failed to decode, never the value.

Deduplication state is persisted **after** the send returns, and the `firstPaidLaunch`
ratchet latches only on a ping the server *accepted* — a conversion is once per install, so
a dropped one is lost forever, unlike a daily boolean that simply re-fires tomorrow.
(odvpn's implementation latches unconditionally; that is a bug this framework fixes, and it
is the reason `PingFlags` is one pure function instead of two hand-written copies.)

Per-app distributions are bucketed on the device (`3-5`, not `4`) and validated against a
server-side allowlist, so neither a single request nor a client typo can leak a raw value or
create an orphan `AGG#DIM#<typo>` partition.

## Consequences

**Good.** The privacy policy in `docs/PRIVACY.md` is literally true and auditable against
the code. "Data Not Linked to You" on App Store Connect is honest. There is no identifier
to leak, subpoena, or accidentally join against. No consent dialog is required for what is
collected. The cohort partitions (`AGG#DAU#free` + `AGG#DAU#paid`) reconcile against the
plain total, giving a built-in sanity check on the client's arithmetic.

**Bad, and accepted:**

- A user who clears app data or reinstalls is counted as a new install. `installs` is
  therefore an upper bound on real installs.
- A device with a wrong clock, or one that travels across the date line, may double-count a
  day. UTC (rather than local time) minimises this; it is not eliminated.
- A determined client could inflate the counters by sending `firstToday: true` repeatedly.
  This is accepted: these are product metrics, not billing. `sharedSecret` auth and reserved
  concurrency bound the damage, and the published numbers make anomalies visible.
- Retention cohorts ("of the devices installed in March, how many are still active in
  June") are **impossible** without an identifier. That question is out of scope, and buying
  it back would cost the entire property above.

## Reversal cost

Adding an identifier is a privacy-policy change first and a code change second. Any PR that
introduces one on this path should be treated as changing the product, not the
implementation.

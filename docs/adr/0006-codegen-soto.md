# 0006 — Code-generated Soto client instead of aws-sdk-swift

**Status:** accepted · 2026-08-24

## Context

The Lambda needs DynamoDB `UpdateItem`, `Query`, `GetItem`, and `PutItem`. Four operations.

- **`awslabs/aws-sdk-swift`** is the official SDK. It was observed to **crash at Lambda cold
  start** in its `aws-crt` TLS layer (a C library built for the CRT's own event loop, not
  NIO's). It is also large: the DynamoDB client alone models every operation and shape.
- **`soto-project/soto`** is the community SDK, pure Swift on NIO, known to work in Lambda.
  Its full `SotoDynamoDB` module is likewise far larger than four operations need.
- **Hand-written signing** over `AsyncHTTPClient` — SigV4 is not something to hand-roll.

## Decision

Depend on **`soto-core` only**, and generate a minimal DynamoDB client into
`server/Sources/Soto/DynamoDB` with `scripts/generate-soto.sh`, covering just the
operations and shapes Keel uses. The generated target builds with relaxed
`SwiftSetting`s (`generatedSettings` in `Package.swift`) because it is not ours to fix
and must not be edited by hand.

## Consequences

**Good.** No `aws-crt`, so no cold-start crash. A small binary and a short cold start,
which is what makes 128 MB and a sub-100 ms warm path realistic. `soto-core` gives correct
SigV4, retries, and credential resolution — the parts worth depending on.

**Bad.** Generated code is checked in, so adding an operation means re-running the script
and reviewing a diff. The generator tracks soto's own version; a `soto-core` major bump may
require regeneration. Anyone reading the tree sees a `Sources/Soto` directory that looks
hand-maintained and isn't — hence the header the script emits and this ADR.

## Revisit when

`aws-sdk-swift` gains a NIO-based HTTP client (or its CRT issue is confirmed fixed on
`PROVIDED_AL2023`/arm64) **and** its binary size is comparable. Until then, the official
SDK's advantage — completeness — is precisely what we don't want in a function that calls
four operations.

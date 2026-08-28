# KeelCore — rules for this target

`KeelCore` is the portable half of the client. It has to compile through
[Skip](https://skip.tools)'s Swift→Kotlin transpiler, because Maxi80 ships this source to
Android. See `docs/adr/0005-two-client-modules.md`.

Nothing in `Package.swift` enforces the rules below — the compiler will happily accept a
violation on Apple platforms and someone's Android build will break instead. Hence this
file, next to the temptation.

## Not allowed here

| Don't | Use instead | Lives in |
|---|---|---|
| `import Observation`, `@Observable` | plain value types; `FeatureFlagSet` | `KeelClient` |
| `import os`, `Logger` | the `KeelLog` protocol | — |
| `import StoreKit` | — | `KeelClient` |
| `import Security`, Keychain | — | `KeelClient` |
| `import SwiftUI` | — | `KeelClient` |
| `Calendar`, `DateComponents`, `DateFormatter` | `UTCDate` (the one UTC helper) | — |
| `ISO8601DateFormatter` | `Date.ISO8601FormatStyle` | — |
| macros of any kind | write it out | — |
| `NSKeyedArchiver`, `NSCache`, other `NS*` types | `Codable`, a `Dictionary` | — |
| third-party dependencies | nothing — this package has none, deliberately | — |

## Allowed and expected

- `Codable`, `Sendable`, `actor`, `async`/`await`, `TaskGroup`, `Duration`
- `URL`, `URLRequest`, `URLSession` — guarded, because Linux splits them out:
  ```swift
  #if canImport(FoundationNetworking)
  import FoundationNetworking
  #endif
  ```
- `String`, `Array`, `Dictionary`, `Result`-free `throws`, typed `throws`
- Protocol witnesses for every effect, so tests need no platform at all

## What belongs here

Wire types, `HTTPTransport`/`URLSessionTransport`, `BackendClient`, and **every pure
decision**: `PingFlags.compute`, `VersionGate.evaluate`, `FeatureFlagSet` lookup. The rule
of thumb — if getting it wrong would be a bug in both the iOS and the Android app, it goes
here so there is one copy to get right.

## Verifying

There is no Skip build in this repo's CI (one package, no Android target). The real check is
Maxi80's Android build after a version bump. If Skip adoption spreads past one app, add the
CI job and delete this paragraph.

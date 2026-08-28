# Golden fixtures

The wire contract, as bytes.

`KeelCore` and `KeelServer` declare the request and response types **twice** — once per package,
by hand — because a shared target would drag soto and NIO into every client app and Skip into
the server (`docs/adr/0005-two-client-modules.md`). These files are what stop the two copies
drifting: every fixture is decoded by one side and produced by the other, in both test suites.

| Fixture | Produced by | Consumed by |
|---|---|---|
| `bootstrap-minimal.json` | `KeelServer` | `KeelCore` |
| `bootstrap-full.json` | `KeelServer` | `KeelCore` |
| `bootstrap-telemetry-disabled.json` | `KeelServer` | `KeelCore` |
| `ping-first-launch.json` | `KeelCore` | `KeelServer` |
| `ping-returning.json` | `KeelCore` | `KeelServer` |
| `stats-empty.json` | `KeelServer` | `KeelCore` |
| `stats-populated.json` | `KeelServer` | `KeelCore` |

## Rules

- **One canonical copy.** Both test targets read these files directly via `#filePath`, not
  through SwiftPM `resources:` — a bundled resource has to live inside its target's directory,
  which would mean two copies, which is the problem these files exist to solve.
- **Compared as JSON, not as bytes.** The tests decode both sides into `JSONValue` and compare.
  Key order and whitespace are not part of the contract; pinning them would turn a formatting
  change into a test failure and teach everyone to ignore the suite.
- **Hand-written, never regenerated.** A fixture regenerated from the code it is meant to check
  proves only that the code equals itself. When a test fails, decide which side is wrong before
  editing either.
- **Timestamps are fixed** (`2026-08-24T10:00:00Z`). Nothing here reads a clock.
- **A new field means a new fixture or an edited one, in the same change.** A field that no
  fixture covers is a field the two packages can disagree about silently.

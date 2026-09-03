# SampleApp — the Keel reference wiring

The complete adoption of Keel in one place: a two-file SwiftUI app and a one-construct
CDK backend. `keel new MyApp` copies and renames it; reading it top to bottom is the
fastest way to learn the framework's shape.

## Backend

```sh
cd backend
npm install
# `@keel/cdk` is a local (file:) dependency — install its own deps once, or the
# next command fails with "Cannot find module 'aws-cdk-lib'":
make -C ../../.. build-cdk    # equivalently: (cd ../../../cdk && npm ci)
npx cdk synth                 # works before any Swift build (placeholder function)
# The real Lambda zips are cross-compiled in a container. The Makefile's `lambda`
# target uses Apple's `container` tool by default — run `container system start`
# once before this step — or switch the target to `--cross-compile docker` to
# build with a running Docker daemon instead.
make -C ../../.. lambda       # build the real function zips (arm64)
export CDK_DEFAULT_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
export CDK_DEFAULT_REGION=eu-west-1   # change to your preferred region
npx cdk deploy                # dev posture: disposable table, generated hostname
```

The stack output `ApiBaseUrl` is what goes into the app's `KeelConfiguration`; the
`TableName` output is what `keel config` and `keel stats dump` take. First useful command
after a deploy:

```sh
keel config set features.confetti true --table <TableName>
```

…and watch it arrive in `/v1/bootstrap` within 60 seconds, no deploy.

For production: `npx cdk deploy -c env=prod` — and configure `domain` first, or synth
will warn about shipping a hostname you do not own.

## App

There is no `.xcodeproj` here on purpose — Xcode project files do not survive templating
well. Create one:

1. Xcode → New Project → iOS/macOS App (SwiftUI). Delete its generated `ContentView`.
2. File → Add Package Dependencies → Add Local… → the Keel repo root. Add `KeelClient`
   (and `KeelCore` comes with it).
3. Drag `App/` into the project.
4. Set `baseURL` in `SampleApp.swift` to the deployed `ApiBaseUrl`.

What the wiring demonstrates, in order of appearance in `SampleApp.swift`:

| Piece | The property it demonstrates |
|---|---|
| `AppFlag` | a flag without a compiled-in default does not compile |
| `RemoteConfigStore.bootstrap()` | cache renders first, network updates it, offline changes nothing |
| `.keelVersionGate` | blocked builds and maintenance windows, driven entirely by `keel config set` |
| `TelemetryService.run` | opt-out first, server switch second, UTC dedup, no identifier anywhere |
| `TelemetryToggle` | the settings row and its honest footer |

## Exercising the gate

```sh
keel config set gate.minSupportedVersion 99.0.0 --table <TableName>   # block everything
keel config set gate.updateURL https://apps.apple.com/... --table <TableName>
# relaunch the app → UpdateRequiredView
keel config set gate.minSupportedVersion null --table <TableName>   # unblock
```

## Telemetry, verified

Launch the app once, then:

```sh
keel stats dump --table <TableName>
```

`installs` is 1, today's `dau` is 1, and the second launch of the day sends nothing —
watch the Lambda log stay silent.

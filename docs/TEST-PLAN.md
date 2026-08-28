# Keel — manual test plan

The human-executed complement to the automated suites (193 server + 96 client Swift
tests, 54 CDK tests). Work top to bottom; each section builds on the previous one.
Mark each item `[x]` in the column that applies and note anything surprising — a test
that "works" but printed something odd is a note, not a pass.

Fill in once per run:

| | |
|---|---|
| Date | 2026-08-27 |
| Machine / Xcode | macOS / Xcode 26 |
| AWS account / region | 401955065246 / eu-central-1 |
| Keel commit | |

Legend: **W** = works, **F** = fails.

---

## 0. Prerequisites

| W | F | Check | How |
|---|---|---|---|
| ✅ | ☐ | Swift 6.2+ toolchain | `swift --version` |
| ✅ | ☐ | Apple `container` CLI installed | `container --version` |
| ✅ | ☐ | Node 20+ | `node --version` |
| ✅ | ☐ | AWS credentials for the target account | `aws sts get-caller-identity` |

Notes:

---

## 1. Automated suites (5 min)

| W | F | Check | How | Expected |
|---|---|---|---|---|
| ✅ | ☐ | Everything builds | `make build` | three green builds |
| ✅ | ☐ | All test suites | `make test` | 96 + 193 Swift tests pass, 54 jest tests pass |
| ✅ | ☐ | Lint | `make lint` | no output, exit 0 |
| ✅ | ☐ | Cross-compile | `make lambda` | `Build complete!`, two zips written |
| ✅ | ☐ | Synth, all auth modes | `make synth` | four modes synth, no errors |

Notes:

---

## 2. Local end-to-end — no AWS (10 min)

Terminal A: `make local` — runs `KeelLambda` with an in-memory store.
Terminal B: the checks below. The local server takes API Gateway *event JSON* on
`POST :7000/invoke`; the payloads live in `server/events/`.

| W | F | Check | How | Expected |
|---|---|---|---|---|
| ✅ | ☐ | Smoke | `make smoke` | `smoke OK` |
| ✅ | ☐ | Bootstrap shape | `curl -s --data @server/events/bootstrap.json localhost:7000/invoke` | 200; body has `schemaVersion`, `telemetry.enabled: true`, `Cache-Control: public, max-age=60` |
| ✅ | ☐ | Ping counts | send `server/events/ping.json` twice, then `server/events/stats.json` | stats body: `installs: 2`, today's `dau` point = 2, version `1.2.0` present |
| ✅ | ☐ | Ping validation | send `server/events/ping-bad.json` | 400, `"code":"validation_error"`, message names `appVersion` but never echoes the bad value |
| ✅ | ☐ | Flattened alias | restart Terminal A with `ALIAS_ROUTES="/station=bootstrap.flattened"` in the env, send `server/events/station.json` | 200; top-level keys, no `app` key |
| ✅ | ☐ | 404 fallback | edit a copy of bootstrap.json with `"proxy": "nope"` | 404 `{"error":"Not found"}` |
| ✅ | ☐ | Missing TABLE_NAME fails loudly | `swift run --package-path server KeelLambda` with no env | process exits with `missingTableName`, never serves |

Notes:

---

## 3. Deploy the dev stack (15 min)

```sh
make lambda                                  # cross-compile via container (arm64)
cd Templates/SampleApp/backend
npm install
export CDK_DEFAULT_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
export CDK_DEFAULT_REGION=eu-west-1          # change to your preferred region
npx cdk deploy                               # dev posture
```

| W | F | Check | Expected |
|---|---|---|---|
| ✅ | ☐ | `make lambda` packages both zips | two product zips in `server/.build/plugins/AWSLambdaBuilder/outputs/` |
| ✅ | ☐ | `cdk synth` prints **no** placeholder warning after `make lambda` | — |
| ✅ | ☐ | `cdk deploy` completes | outputs `ApiBaseUrl`, `TableName`, `SiteUrl` |
| ✅ | ☐ | Table shape | console: `pk`/`sk` keys, TTL on `ttl`, on-demand, **no GSI** |
| ✅ | ☐ | Function config | 128 MB, arm64, `provided.al2023`, `TABLE_NAME` set |
| ✅ | ☐ | IAM is minimal | function role: `UpdateItem`/`Query`/`GetItem` only, **no Scan** |

Record here — everything below uses them:

- `ApiBaseUrl`: https://zytv7sawxb.execute-api.eu-central-1.amazonaws.com
- `TableName`: SampleApp-dev-BackendTable11108670-12ALBR6Z2DCTD
- `SiteUrl`: https://d3nsk0l7ksogz0.cloudfront.net

Notes:

---

## 4. Deployed API (10 min)

`export BASE=<ApiBaseUrl>`

| W | F | Check | How | Expected |
|---|---|---|---|---|
| ✅ | ☐ | Bootstrap | `curl -si "$BASE/v1/bootstrap?appVersion=1.0.0&platform=ios"` | 200, `max-age=60`, `telemetry.enabled: true` |
| ✅ | ☐ | Ping | `curl -si -X POST "$BASE/v1/ping" -H 'Content-Type: application/json' -d '{"firstPingEver":true,"firstToday":true,"firstThisMonth":true,"firstThisVersion":true,"firstPaidLaunch":false,"appVersion":"1.0.0","osVersion":"26.1","platform":"ios","licenseState":"free"}'` | 200 `{"ok":true}` |
| ✅ | ☐ | Stats | `curl -si "$BASE/v1/stats"` | 200, `max-age=300`, `installs: 1`, today's dau = 1 |
| ✅ | ☐ | Items in the table | console or `aws dynamodb query` on `AGG#INSTALLS` | `AGG#INSTALLS/TOTAL count=1`; dated items carry a `ttl` ≈ +400 days, totals carry none |
| ✅ | ☐ | Unknown route | `curl -si "$BASE/nope"` | 404 from API Gateway |
| ✅ | ☐ | Function logs are clean | CloudWatch log group | no errors; **no request bodies, IPs, or User-Agents anywhere** |

Notes:

---

## 5. Live config — the control surface (10 min)

Run from the repo root with `--table <TableName>`. Each change must land **within 60 s,
with no deploy**.

```sh
export TABLE_NAME=<TableName>
export AWS_REGION=eu-central-1
swift run --package-path server keel config get --table $TABLE_NAME
```

| W | F | Check | How | Expected |
|---|---|---|---|---|
| ✅ | ☐ | CLI reads empty config | `keel config get --table $TABLE_NAME` | empty defaults + stderr note |
| ✅ | ☐ | Flag flip | `keel config set features.confetti true --table $TABLE_NAME` → curl bootstrap ≤60 s later | `"features":{"confetti":true}` |
| ✅ | ☐ | Telemetry kill switch | `keel config set telemetry.enabled false` → send a ping | 200 `{"ok":true}` but **no counter moves** (stats unchanged) |
| ✅ | ☐ | Kill switch on the wire | curl bootstrap | `telemetry.enabled: false` |
| ✅ | ☐ | Re-enable | `keel config set telemetry.enabled null` (or `true`) | counting resumes |
| ✅ | ☐ | Gate: block | `keel config set gate.minSupportedVersion 99.0` → curl bootstrap with `appVersion=1.0.0` | `gate.minSupportedVersion` present |
| ✅ | ☐ | Gate: current build unaffected | curl with `appVersion=99.0` | **no `gate` key at all** |
| ✅ | ☐ | Gate: unparseable version fails open | curl with `appVersion=1.0.0-beta.3` | no `gate` key (fails open) |
| ✅ | ☐ | Un-block | `keel config set gate.minSupportedVersion null` | gate gone |
| ✅ | ☐ | Stats dump | `keel stats dump --table …` | same JSON as `GET /v1/stats` |
| ✅ | ☐ | Typo'd config is rejected | `keel config replace --file /tmp/garbage.json` | decode error, **nothing stored** |

Notes:

---

## 6. Dashboard (5 min)

Open `SiteUrl` in a browser.

| W | F | Check | Expected |
|---|---|---|---|
| ✅ | ☐ | Page renders | hero counters, DAU/MAU charts, version/OS/platform bars |
| ✅ | ☐ | Same-origin data | network tab: `/v1/stats` served from `SiteUrl`, no CORS errors |
| ✅ | ☐ | Edge cache | second reload: `x-cache: Hit from cloudfront` on `/v1/stats` |
| ✅ | ☐ | Numbers match §4 | installs and today's DAU equal what curl showed |
| ✅ | ☐ | Empty-state | windows with no data show "No data" text, not broken charts |
| ✅ | ☐ | Dark mode | flip system appearance; page follows |
| ✅ | ☐ | Reduced motion | enable in system settings, reload: no animations |
| ✅ | ☐ | Dimensions appear dynamically | `keel config set` a `telemetry.dimensions` entry, send a ping with that dimension, reload after cache expiry | a new panel, buckets in declared order |

Notes:

---

## 7. SampleApp in the simulator (20 min)

Follow `Templates/SampleApp/README.md`: create the Xcode project, add the local Keel
package, set `baseURL` to `ApiBaseUrl`.

| W | F | Check | How | Expected |
|---|---|---|---|---|
| ✅ | ☐ | First launch, online | run | Source: `network`; flags at defaults |
| ✅ | ☐ | Flag arrives live | `keel config set features.confetti true`, relaunch | confetti row reads `on` |
| ✅ | ☐ | Disk cache tier | enable Airplane-mode-ish (Link Conditioner 100% loss) or point `baseURL` at a black-holed host, relaunch | Source: `diskCache`; flag values from the last good fetch |
| ✅ | ☐ | Compiled defaults tier | fresh install (delete app), still offline, launch | Source: `none`; app fully usable |
| ✅ | ☐ | Version gate blocks | `gate.minSupportedVersion 99.0` + `gate.updateURL`, relaunch | full-screen Update Required; **no way to navigate around it** |
| ✅ | ☐ | Soft update banner | `minSupportedVersion null`, `recommendedVersion 99.0`, relaunch | dismissible banner; returns next launch |
| ✅ | ☐ | Maintenance | `gate.maintenance.message "Back at 14:00 UTC"`, relaunch | maintenance screen, message shown as plain text |
| ✅ | ☐ | Ping fires once per day | launch, check `keel stats dump`; relaunch | first launch: dau +1; second launch: **no request at all** (function log silent) |
| ✅ | ☐ | Dedup re-arms | delete `keel.telemetry.lastPingDate` from UserDefaults (or advance the sim clock a day), relaunch | pings again |
| ✅ | ☐ | Upgrade pings | bump `CFBundleShortVersionString`, relaunch same day | ping with `firstThisVersion`; version spread moves |
| ✅ | ☐ | Telemetry toggle | Settings → toggle off, relaunch | no request; toggle on → resumes next UTC day boundary |
| ✅ | ☐ | Toggle beats server | toggle off **and** `telemetry.enabled true` | still no request — user opt-out wins |

Notes:

---

## 8. Auth modes (15 min, optional but recommended once)

All commands below run from `Templates/SampleApp/backend/`. After each mode change,
redeploy and re-export `BASE`:

```sh
cd Templates/SampleApp/backend
export CDK_DEFAULT_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
export CDK_DEFAULT_REGION=eu-central-1
```

### 8a. sharedSecret

**1. Create the SSM SecureString (once):**

```sh
aws ssm put-parameter \
  --name /keel/sampleapp/dev/api-secret \
  --type SecureString \
  --value "$(openssl rand -base64 32)" \
  --region eu-central-1
```

Save the secret for later:

```sh
SECRET=$(aws ssm get-parameter \
  --name /keel/sampleapp/dev/api-secret \
  --with-decryption --query Parameter.Value --output text \
  --region eu-central-1)
echo "$SECRET"
```

**2. Edit `lib/sample-app-stack.ts`** — change the auth line:

```ts
auth: KeelAuth.sharedSecret({ parameterName: "/keel/sampleapp/dev/api-secret" }),
```

**3. Deploy:**

```sh
npx cdk deploy
```

Re-export the base URL (it may have changed if the API was recreated):

```sh
export BASE=$(aws cloudformation describe-stacks \
  --stack-name SampleApp-dev --region eu-central-1 \
  --query 'Stacks[0].Outputs[?starts_with(OutputKey,`BackendApiBaseUrl`)].OutputValue' \
  --output text)
echo "$BASE"
```

**4. Run the checks:**

```sh
# Ping WITHOUT header → expect 401
curl -si -X POST "$BASE/v1/ping" \
  -H 'Content-Type: application/json' \
  -d '{"firstPingEver":false,"firstToday":true,"firstThisMonth":false,"firstThisVersion":false,"firstPaidLaunch":false,"appVersion":"1.0.0","osVersion":"26.1","platform":"ios","licenseState":"free"}'

# Ping WITH correct header → expect 200
curl -si -X POST "$BASE/v1/ping" \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $SECRET" \
  -d '{"firstPingEver":false,"firstToday":true,"firstThisMonth":false,"firstThisVersion":false,"firstPaidLaunch":false,"appVersion":"1.0.0","osVersion":"26.1","platform":"ios","licenseState":"free"}'

# Wrong secret → expect 401
curl -si -X POST "$BASE/v1/ping" \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer WRONG_SECRET_HERE" \
  -d '{"firstPingEver":false,"firstToday":true,"firstThisMonth":false,"firstThisVersion":false,"firstPaidLaunch":false,"appVersion":"1.0.0","osVersion":"26.1","platform":"ios","licenseState":"free"}'

# /v1/stats still public (no header) → expect 200
curl -si "$BASE/v1/stats"
```

| W | F | Mode | Check | Expected |
|---|---|---|---|---|
| ✅ | ☐ | sharedSecret | curl ping **without** `Authorization` header | 401 |
| ✅ | ☐ | sharedSecret | curl ping **with** `Authorization: Bearer $SECRET` | 200 `{"ok":true}` |
| ✅ | ☐ | sharedSecret | curl ping with **wrong** secret | 401; authorizer log says "Unauthorized request" and **never logs the presented value** |
| ✅ | ☐ | sharedSecret | `/v1/stats` without any header | 200 (public route) |

### 8b. iam

**1. Edit `lib/sample-app-stack.ts`** — change the auth line:

```ts
auth: KeelAuth.iam(),
```

**2. Deploy:**

```sh
npx cdk deploy
```

Re-export:

```sh
export BASE=$(aws cloudformation describe-stacks \
  --stack-name SampleApp-dev --region eu-central-1 \
  --query 'Stacks[0].Outputs[?starts_with(OutputKey,`BackendApiBaseUrl`)].OutputValue' \
  --output text)
```

**3. Run the checks:**

```sh
# Unsigned ping → expect 403
curl -si -X POST "$BASE/v1/ping" \
  -H 'Content-Type: application/json' \
  -d '{"firstPingEver":false,"firstToday":true,"firstThisMonth":false,"firstThisVersion":false,"firstPaidLaunch":false,"appVersion":"1.0.0","osVersion":"26.1","platform":"ios","licenseState":"free"}'

# SigV4-signed ping → expect 200
awscurl --service execute-api --region eu-central-1 \
  -X POST "$BASE/v1/ping" \
  -H 'Content-Type: application/json' \
  -d '{"firstPingEver":false,"firstToday":true,"firstThisMonth":false,"firstThisVersion":false,"firstPaidLaunch":false,"appVersion":"1.0.0","osVersion":"26.1","platform":"ios","licenseState":"free"}'

# /v1/stats still public → expect 200
curl -si "$BASE/v1/stats"
```

| W | F | Mode | Check | Expected |
|---|---|---|---|---|
| ✅ | ☐ | iam | unsigned ping | 403 |
| ✅ | ☐ | iam | SigV4-signed ping (`awscurl --service execute-api`) | 200 `{"ok":true}` |
| ✅ | ☐ | iam | `/v1/stats` without any header | 200 (public route) |

### 8c. Restore to none

**After testing, switch back to `KeelAuth.none()` and redeploy:**

```sh
# Edit lib/sample-app-stack.ts → auth: KeelAuth.none(),
npx cdk deploy
```

Notes:

---

## 9. IAP (sandbox — only if the app sells something)

Requires a real App Store Connect app with sandbox IAP products. Skip if you have none —
the IAP layer is fully tested by the automated suite; this section verifies the wiring
end-to-end.

### Prerequisites

1. An app registered in App Store Connect with at least one product (e.g. `com.example.myapp.pro`)
2. A sandbox tester account (App Store Connect → Users → Sandbox Testers)
3. The device signed into that sandbox account (Settings → App Store → Sandbox Account)

### Deploy with IAP enabled

Edit `lib/sample-app-stack.ts`:

```ts
const backend = new KeelBackend(this, "Backend", {
  appName: "sampleapp",
  envName: props.envName,
  auth: KeelAuth.none(),
  lambdaPackagePath: "../../../server",
  iap: {
    bundleId: "com.example.myapp",          // your real bundle id
    productIds: ["com.example.myapp.pro"],   // your real product id(s)
  },
});
```

Deploy: `npx cdk deploy`

Point App Store Connect's **Server-to-Server Notification URL** (App Store Connect →
App → App Information → App Store Server Notifications) at:
`<ApiBaseUrl>/v1/appstore-notification`

### Run the checks

```sh
export BASE=<ApiBaseUrl>

# 1. POST /v1/purchase — send a real JWS from StoreKit 2's Transaction.jwsRepresentation
#    (capture it from the device with a debug breakpoint or os_log)
curl -si -X POST "$BASE/v1/purchase" \
  -H 'Content-Type: application/json' \
  -d '{"userId":"sandbox-user-1","jws":"<paste the real JWS here>"}'
# → 200; body has entitlements array with state "active", isEntitled: true

# 2. GET /v1/entitlement — read it back
curl -si "$BASE/v1/entitlement?userId=sandbox-user-1"
# → 200; same entitlement

# 3. Replay the same JWS (idempotency)
curl -si -X POST "$BASE/v1/purchase" \
  -H 'Content-Type: application/json' \
  -d '{"userId":"sandbox-user-1","jws":"<same JWS>"}'
# → 200; still one entitlement, not two

# 4. Garbage JWS
curl -si -X POST "$BASE/v1/purchase" \
  -H 'Content-Type: application/json' \
  -d '{"userId":"sandbox-user-1","jws":"not.a.real.jws"}'
# → 400, "code":"validation_error"

# 5. Unknown user
curl -si "$BASE/v1/entitlement?userId=nobody"
# → 200, empty entitlements list (not 404)

# 6. Sandbox refund: trigger from App Store Connect → Sandbox → Manage Testers →
#    select tester → view purchases → request refund.
#    The notification should arrive at /v1/appstore-notification and flip the
#    entitlement to "revoked". Verify:
curl -si "$BASE/v1/entitlement?userId=sandbox-user-1"
# → state: "revoked", isEntitled: false

# 7. Check the DynamoDB items
aws dynamodb query --table-name $TABLE_NAME --region eu-central-1 \
  --key-condition-expression "pk = :pk" \
  --expression-attribute-values '{":pk":{"S":"ENT#sandbox-user-1"}}' \
  --query 'Items[*].{pk:pk.S,sk:sk.S,state:state.S}' --output table

# 8. In-app: EntitlementService.licenseState should flip to .paid after purchase,
#    .free after refund (observe in the debug console)
```

| W | F | Check | Expected |
|---|---|---|---|
| ☐ | ☐ | Sandbox purchase → `POST /v1/purchase` with the JWS | 200; entitlement `active`, `isEntitled: true`, `environment: "Sandbox"` |
| ☐ | ☐ | `GET /v1/entitlement?userId=…` | same entitlement |
| ☐ | ☐ | Replay the same JWS | still one entitlement (idempotent) |
| ☐ | ☐ | Garbage JWS | 400, one undifferentiated `validation_error` |
| ☐ | ☐ | Unknown user | 200, empty list (not 404) |
| ☐ | ☐ | Sandbox refund (App Store Connect → refund test) | notification arrives; entitlement flips to `revoked` |
| ☐ | ☐ | `ENT#`/`TXN#` items in the table | both present, readable JSON payloads |
| ☐ | ☐ | EntitlementService in-app | `licenseState` flips to `.paid` after purchase, `.free` after refund |

Notes: **Skipped** — no IAP products configured for the SampleApp.

---

## 10. Custom domain (before first prod release)

Requires a domain you own and an ACM certificate in the **same region** as the API
(not us-east-1 like CloudFront requires — this is API Gateway's regional cert).

### Setup

**1. Request or import a certificate** (if you don't already have one):

```sh
aws acm request-certificate \
  --domain-name api.myapp.com \
  --validation-method DNS \
  --region eu-central-1 \
  --query CertificateArn --output text
# → arn:aws:acm:eu-central-1:...:certificate/...
# Complete DNS validation (add the CNAME ACM shows you)
```

**2. Edit `lib/sample-app-stack.ts`** — add the `domain` prop:

```ts
import * as acm from "aws-cdk-lib/aws-certificatemanager";

// inside the constructor, before new KeelBackend:
const certificate = acm.Certificate.fromCertificateArn(
  this, "Cert", "arn:aws:acm:eu-central-1:...:certificate/...");

const backend = new KeelBackend(this, "Backend", {
  appName: "sampleapp",
  envName: "prod",               // prod to also verify the warning behavior
  auth: KeelAuth.none(),
  lambdaPackagePath: "../../../server",
  domain: {
    domainName: "api.myapp.com",  // your real domain
    certificate,
  },
});
```

**3. Deploy:**

```sh
npx cdk deploy
```

The outputs will include `RegionalDomainName` and `RegionalHostedZoneId`.

**4. Create the DNS record** (outside CDK — DNS is not Keel's concern):

```sh
# For Route 53:
aws route53 change-resource-record-sets --hosted-zone-id <YOUR_ZONE_ID> \
  --change-batch '{
    "Changes": [{
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "api.myapp.com",
        "Type": "A",
        "AliasTarget": {
          "DNSName": "<RegionalDomainName from stack output>",
          "HostedZoneId": "<RegionalHostedZoneId from stack output>",
          "EvaluateTargetHealth": true
        }
      }
    }]
  }'

# For external DNS (Cloudflare, etc.) — create a CNAME:
#   api.myapp.com → <RegionalDomainName>
#   Keep it DNS-only (no proxy) — API Gateway handles TLS.
```

**5. Run the checks:**

```sh
# Prod synth WITHOUT domain should warn
npx cdk synth -c env=prod 2>&1 | grep "prod-without-domain"
# → warning about AWS-generated hostname

# API answers on the custom domain
curl -si "https://api.myapp.com/v1/stats"
# → 200

# Paths are the same
curl -si "https://api.myapp.com/v1/bootstrap?appVersion=1.0.0&platform=ios"
# → 200, same shape as the execute-api URL
```

| W | F | Check | Expected |
|---|---|---|---|
| ☐ | ☐ | Prod synth without `domain` warns | `cdk synth -c env=prod` prints the AWS-generated-hostname warning |
| ☐ | ☐ | With `domain` + existing cert | deploy outputs `RegionalDomainName` / `RegionalHostedZoneId` |
| ☐ | ☐ | DNS-only CNAME → API answers on the name | `curl https://api.<domain>/v1/stats` → 200 |
| ☐ | ☐ | `/v1` paths pass through un-stripped | bootstrap works at the same path as on the raw URL |

Notes: **Skipped** — no custom domain configured for SampleApp dev.

Notes:

---

## 11. Teardown

| W | F | Check | Expected |
|---|---|---|---|
| ✅ | ☐ | `npx cdk destroy` (dev) | completes; **no orphan table left** (dev is DESTROY, no fixed name) |
| ✅ | ☐ | Re-deploy afterwards | succeeds first try — the orphan-table trap stays dead |

Notes:

---

## Verdict

| | |
|---|---|
| Sections passed | 9/11 (§9 IAP and §10 custom domain skipped — no products / no domain configured) |
| Blocking failures | none |
| Ready to retrofit the first app? | yes |

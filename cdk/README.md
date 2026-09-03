# @keel/cdk

CDK constructs for a [Keel](../README.md) backend: one DynamoDB table, one Swift Lambda, an
HTTP API with pluggable auth, and an optional static stats dashboard.

## Install

```sh
npm install @keel/cdk
```

`aws-cdk-lib` and `constructs` are peer dependencies — you bring your own versions.

## Use

```ts
import { KeelBackend, KeelAuth, KeelStatsSite } from "@keel/cdk";

const backend = new KeelBackend(this, "Backend", {
  appName: "myapp",
  envName: "prod",
  auth: KeelAuth.sharedSecret({ parameterName: "/myapp/api-token" }),
  publicRoutes: ["/v1/stats"],
  budgetEmail: "me@example.com",
});

new KeelStatsSite(this, "Stats", {
  api: backend.httpApi,
  domainName: "stats.myapp.com",
  certificate: usEast1Certificate, // CloudFront's rule: us-east-1, always
});
```

Build the Lambda first — `make lambda` at the repo root — so the construct finds the zip the
`AWSLambdaBuilder` plugin produces. Before the first build it falls back to a placeholder
function so `cdk synth` still works.

## Auth modes

| `KeelAuth.…` | Mechanism |
|---|---|
| `none()` | no authorizer; everything public |
| `sharedSecret({ parameterName })` | Lambda authorizer comparing a header against an SSM parameter |
| `iam()` | `AWS_IAM`, SigV4 from Cognito Identity |
| `jwt({ issuer, audience })` | HTTP API JWT authorizer |

`publicRoutes` opts individual paths out of whichever mode you chose, so the dashboard can
read `/v1/stats` while the rest of the API stays authorized.

## Migrating an existing table

An app already running its own counters hands its live table in as `existingTable`, and the
construct uses it instead of creating one — no orphan table left behind, and the existing
`AGG#` history stays where the dashboard already reads it.

```ts
existingTable: dynamodb.Table.fromTableName(this, "Existing", "myapp-prod-counters"),
```

The table has to carry the contract's key schema (`pk`/`sk`, TTL on `ttl`) — CDK cannot check
that for an imported resource. The same least-privilege grants are applied either way.

## Throttling

The default stage gets `{ rateLimit: 20, burstLimit: 40 }` unless `throttling` says otherwise.
`/v1/ping` is public in every deployment, and a client pings at most once per UTC day, so 20
requests/sec sits far above any honest traffic while still capping a runaway client:

```ts
throttling: { rateLimit: 5, burstLimit: 10 }
```

## Custom domain

Shipped clients compile in their base URL, so production must not use the generated
`*.execute-api.<region>.amazonaws.com` hostname — it changes whenever the API is replaced
(`docs/adr/0007-stable-base-url.md`).

```ts
domain: {
  domainName: "api.myapp.com",
  certificate: acm.Certificate.fromCertificateArn(this, "Cert", certArn),
}
```

The certificate is an **input**: CDK can only auto-validate one when it owns the hosted zone,
so with DNS elsewhere `CertificateValidation.fromDns()` hangs the first deploy on a record
nobody created. It must be in the **API's own region** — CloudFront (`KeelStatsSite`) needs
`us-east-1` instead, so one name served both ways needs two certificates.

For DNS outside Route 53, point a CNAME at `backend.regionalDomainName`. In Cloudflare it must
be **DNS-only, not proxied**, and the `_<hash>` ACM validation record has to stay in place
forever — renewal only works while it resolves, so deleting it breaks the certificate 13
months later.

## Development

```sh
npm run build     # tsc
npm test          # jest, assertions on the synthesized template
npm run lint      # eslint
```

`lib/contract.ts` holds the route paths, table key names, and TTL that this package shares
with the Swift server. Those literals are duplicated in Swift on purpose (`docs/ARCHITECTURE.md`
§3) — if you change one, change both. `lib/domain.ts` holds the custom-domain options and
their synth-time validation.

`tsconfig.json` deliberately does **not** set `exactOptionalPropertyTypes`: aws-cdk-lib's own
type declarations fail under it.

## Status

`KeelBackend`, `KeelAuth`, and `KeelStatsSite` are implemented and covered by the
assertions suite. App Store notification verification is opt-in via
`KeelBackendProps.appStoreNotifications` (verification only — no entitlement model).

To prove a mode synthesizes outside jest:

```sh
npx cdk --app "npx tsx test/synth-app.ts" synth -c auth=sharedSecret --quiet
```

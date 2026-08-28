# 0007 — The base URL is permanent: a custom domain from the first release

**Status:** accepted · 2026-08-24

## Context

Bootstrap can change anything about a shipped app except **how to reach bootstrap**. The
base URL is compiled into every build that has left the App Store, so it is the one value
the remote-config mechanism cannot fix. If it stops resolving, those installs lose their
feature flags, their kill switch, and their version gate — permanently, and silently.

AWS's generated hostnames are all derived from a resource id:

| Front door | Hostname | Changes when |
|---|---|---|
| Lambda Function URL | `<hash>.lambda-url.<region>.on.aws` | the **function** is replaced |
| API Gateway HTTP API | `<api-id>.execute-api.<region>.amazonaws.com` | the **API** is replaced |

"Replaced" is not exotic. A stack deleted and recreated in a dev-then-prod migration, a
region move, a change to a CloudFormation property that forces replacement, or switching
front door (Orthanc is on a Function URL today and would move to an HTTP API to adopt
Keel) all produce a new hostname. At that moment every already-installed copy of the app is
talking to nothing.

Orthanc, Maxi80, and odvpn all currently ship a generated hostname. odvpn is the first to
fix it, which is what prompted this ADR.

## Decision

**Every Keel deployment that serves a shipped client does so under a DNS name the app
owns, in place before the first public release.** `/v1/…` versioning gives a second axis for
contract changes; the domain gives an axis for infrastructure changes.

Two mechanisms, both supported:

| Mechanism | Cert region | Use when |
|---|---|---|
| API Gateway regional custom domain (`apigwv2.DomainName` + `ApiMapping`) | the API's own region | backend only, or the dashboard lives elsewhere |
| CloudFront distribution with an API origin (`KeelStatsSite`) | `us-east-1` | you also serve the stats dashboard, want it same-origin, and want `/v1/stats` edge-cached |

Doing both for one name needs **two certificates**, because the required regions differ.

### The certificate is an input, never created by the construct

`KeelBackend`'s `domain` prop takes an `acm.ICertificate`. It does not create one. Three
reasons, in order of how much trouble they cause:

1. **DNS may not be in Route 53.** CDK can only auto-validate a DNS-validated certificate
   when it can write the validation record itself, which means a Route 53 hosted zone.
   odvpn's DNS is on Cloudflare (`cdk/lib/server-cert-stack.ts` does ACME DNS-01 with a
   Cloudflare token). With an external provider, `CertificateValidation.fromDns()` with no
   zone leaves the **first deploy hanging** on a CNAME nobody has created, for up to hours,
   then rolling back.
2. **Certificate lifecycle should not gate application deploys.** Issuance and validation
   happen once; the function is deployed constantly. Coupling them means an ACM hiccup
   blocks a code push.
3. **The region mismatch above** is invisible if the construct creates the cert in the
   stack's region — it would work for API Gateway and silently be wrong for CloudFront.

The construct exposes `regionalDomainName` and `regionalHostedZoneId` as outputs so an
external DNS provider can be pointed at the target.

### With external DNS, the validation record stays forever

ACM renews a DNS-validated certificate automatically **only while the `_<hash>` validation
CNAME still resolves**. Deleting it after issuance — the natural instinct, since the cert is
already issued — makes renewal fail 13 months later, with an email to the account's contact
address as the only warning. Leave it in place. In Cloudflare it must be **DNS-only, not
proxied**, for both the validation record and the API record: an orange-cloud CNAME
terminates TLS at Cloudflare and forwards to an endpoint whose certificate expects to be
addressed directly.

### Dev and staging

A stage nobody has shipped a client against does not need this — the generated hostname is
fine, and dev's `DESTROY` removal policy makes churn expected. `domain` is optional, and
`KeelBackend` warns (an annotation, not an error) when `envName` is `prod` and `domain` is
absent.

## Consequences

**Good.** The infrastructure under the API becomes replaceable: the stack can be
rebuilt, the front door swapped, the region changed, without any consequence for installed
apps. `/v1/bootstrap` at a name you own is also simply testable by hand and legible in a
privacy policy.

**Bad.** A domain, a certificate, and a DNS record are prerequisites of the first release
rather than a later improvement. A certificate is one more thing that expires. And the app
is now pinned to a name that must be renewed and paid for as long as any install survives —
which, for the version gate to keep working, is indefinitely.

## The escape hatch we are deliberately not building

For an app that has *already* shipped a generated hostname, the obvious rescue is to have
`/v1/bootstrap` return the new base URL and let clients migrate themselves: hit the old
host once, learn the new one, cache it, use it from then on.

Not in v1. It turns the base URL into remotely-controlled state, which means a hijacked or
expired old domain can redirect a client to an attacker's endpoint — a strictly worse
failure mode than the one it fixes. If it is ever added it needs the new host constrained to
a compiled-in allowlist of suffixes, which is most of the benefit of just owning the domain
in the first place. The supported migration is: stand up the custom domain in front of the
*existing* API (which does not replace it), ship a build that uses it, and keep the old
generated hostname answering for as long as old installs matter.

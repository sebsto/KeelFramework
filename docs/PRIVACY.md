# Privacy policy template — Keel telemetry

Copy the relevant sections into your app's published privacy policy. Every claim below is
a property the framework's code is built to keep true; `docs/ARCHITECTURE.md` §9 explains
the mechanism behind each one, and the tests in `Tests/KeelCoreTests` and
`server/Tests/KeelServerTests` are what stop them from quietly becoming false.

**If you change any of these claims, change the policy first and the code second.**

---

## What <App> collects

<App> collects anonymous usage counters so I can tell how many people use it, on which
platforms and versions, and whether a feature is worth keeping. That is the whole purpose.

When the app launches, it may send a single message containing:

- whether this is the first launch ever, the first today, the first this month, the first
  on this version, and the first after a purchase — five yes/no answers;
- the app version (e.g. `2.1.0`) and the OS version (e.g. `26.1`);
- the platform (e.g. `ios`);
- whether the app is in its free or paid state;
- <optional: coarse ranges for app-specific settings, e.g. "how many profiles are
  configured, as one of 1-2 / 3-5 / 6-10 / 11+">.

That is the entire message. There is nothing else in it.

## What <App> does not collect

- **No identifier of any kind.** No account, no device id, no advertising identifier, no
  hashed or salted machine identifier, no cookie, no session. The app does not have one to
  send, and no code in it derives one.
- **No content.** <adapt: your files, credentials, playback history, browsing, documents,
  and their names never leave the device.>
- **No location, no contacts, no photos, no health data.**
- **No exact numbers about your setup.** Where a count is reported, it is turned into a
  coarse range *on your device* before it is sent, so even a single message cannot say
  exactly how many of something you have.
- **No IP address, request contents, or User-Agent are recorded.** The server logs neither
  the message nor anything about the connection that carried it.

## How the counts work without an identifier

Because no identifier is sent, the server cannot tell one device from another. It only ever
adds 1 to a shared counter — "daily active devices on 2026-08-24", "devices running 2.1.0
this month". Your device decides on its own whether today's launch is the first one, by
remembering the date locally.

The trade-off is deliberate: if you delete the app's data or reinstall it, you are counted
as a new install. Making that number more accurate would require identifying you, and that
is a worse deal.

## The numbers are public

Everything collected is published, unaggregated-by-nothing-else, at
`<https://your.app/stats>`. If a number is not on that page, it is not collected.

## Turning it off

Settings ▸ <Privacy> ▸ **Send anonymous usage statistics**. Turning it off stops the
message being sent at all — the app does not send a "user opted out" signal instead. It is
on by default; nothing about it is on by default and hidden.

## Configuration fetched at launch

Separately from the counters, the app fetches its configuration at launch (feature
availability, the minimum supported version, support links). That request carries the app
version, platform, OS version, and locale — the information needed to answer it correctly —
and nothing else. It is a read; nothing is stored about it.

## Retention

Counters older than 400 days are deleted automatically. Install and purchase totals are
running totals with no dates attached.

## <If your app has in-app purchases>

Purchases are processed by Apple. <App> receives a signed receipt from Apple and verifies it.
<If your server records what a purchase grants: and stores the entitlement it grants against
<your Apple-provided account identifier / your app account token>.> It never receives your
payment details.

## Changes to this policy

<Date the policy and say where its history lives — e.g. this file in a public repo.>

---

## Notes for the developer (delete before publishing)

- The `PrivacyInfo.xcprivacy` fragment in `Sources/KeelClient/Resources/` declares the
  matching manifest entries: `NSPrivacyCollectedDataTypes` with
  `NSPrivacyCollectedDataTypeProductInteraction`, `Collected: true`, `Linked: false`,
  `Tracking: false`, purpose `Analytics`. Merge it into your app target's manifest.
- Apple's "Data Not Linked to You" claim on App Store Connect is only honest if you have
  not added an identifier. That is the invariant.
- If you add a dimension to `pingDimensions`, add it to the list above and re-publish the
  policy. A new dimension is new data collection.
- If you ever add a device identifier, this template no longer applies to your app and the
  framework's `docs/ARCHITECTURE.md` §9 stops describing your deployment.

# Keel stats dashboard

A dependency-free static page over `GET /v1/stats`: inline SVG, no charting library, no
CDN, `prefers-reduced-motion` and dark mode respected. `KeelStatsSite` deploys this
directory to S3 behind CloudFront with `/v1/*` forwarded to the API, so the page and its
data are same-origin.

## Rebrand

`tokens.css` is the entire restyling surface — colors, fonts, the accent, the cohort
lanes. Copy this directory into your app's repo, replace `tokens.css`, and point
`KeelStatsSite`'s `dashboardPath` at your copy. `style.css` and `stats.js` should
survive a rebrand untouched.

## Panels

Hero counters (installs, conversions, active today/this month), the DAU line and MAU
columns split by license state (the trial lane appears only when the window has any),
ranked bars for app versions, OS versions and platforms, and one bar panel per
app-declared dimension — created at runtime from the response, so a `keel config set`
adding a dimension shows up here without an HTML edit.

## Local development

Open the page with `?api=https://<your-api>` to point it at a deployed backend before
DNS exists:

```
python3 -m http.server --directory dashboard 8080
open "http://localhost:8080/?api=https://xxxx.execute-api.eu-central-1.amazonaws.com"
```

(That cross-origin call needs the API reachable; the deployed page never needs CORS
because CloudFront serves both.)

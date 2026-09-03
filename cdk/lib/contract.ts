/**
 * The parts of the wire contract that infrastructure has to know about.
 *
 * These literals are duplicated in Swift (`KeelServer.Route`, `KeelCore.Route`) and
 * pinned to that copy by the golden-JSON fixtures both test suites read. Changing a
 * path here without changing it there produces a route that synthesizes and 404s.
 *
 * See docs/ARCHITECTURE.md §3.
 */

/** Version of the JSON envelope `/v1/bootstrap` and `/v1/stats` emit. */
export const KEEL_SCHEMA_VERSION = 1;

/** A route the framework's Lambda serves. */
export interface KeelRoute {
  readonly method: "GET" | "POST";
  readonly path: string;
  /** Framework routes are always mounted; optional ones only when the app opts in. */
  readonly optional: boolean;
  /** `Cache-Control: public, max-age=<seconds>`, or undefined for no caching. */
  readonly maxAgeSeconds?: number;
}

/** The three routes every Keel backend serves. */
export const KEEL_CORE_ROUTES: readonly KeelRoute[] = [
  { method: "GET", path: "/v1/bootstrap", optional: false, maxAgeSeconds: 60 },
  { method: "POST", path: "/v1/ping", optional: false },
  { method: "GET", path: "/v1/stats", optional: false, maxAgeSeconds: 300 },
];

/**
 * The App Store server-notification route, mounted only when `KeelBackend` is given
 * `appStoreNotifications`. Verification-only: the framework verifies Apple's JWS and hands the
 * app a verified payload — it does not model purchases or entitlements. Always unauthenticated
 * when mounted, because Apple's servers hold no credentials of ours and the JWS signature is the
 * boundary.
 */
export const KEEL_APPSTORE_NOTIFICATION_ROUTE: KeelRoute = {
  method: "POST",
  path: "/v1/appstore-notification",
  optional: true,
};

/**
 * DynamoDB attribute names. The table is single-table with a `pk`/`sk` pair and a
 * TTL attribute; `KeelBackend` needs these to declare the key schema, and the Swift
 * side needs them to build keys. See docs/ARCHITECTURE.md §4.
 */
export const KEEL_TABLE_KEYS = {
  partitionKey: "pk",
  sortKey: "sk",
  timeToLiveAttribute: "ttl",
} as const;

/** How long dated counter partitions live. Totals have no TTL. */
export const KEEL_COUNTER_TTL_DAYS = 400;

import {
  KEEL_APPSTORE_NOTIFICATION_ROUTE,
  KEEL_CORE_ROUTES,
  KEEL_COUNTER_TTL_DAYS,
  KEEL_SCHEMA_VERSION,
  KEEL_TABLE_KEYS,
} from "../lib";

describe("wire contract constants", () => {
  test("the three framework routes are all mandatory", () => {
    expect(KEEL_CORE_ROUTES.map((r) => `${r.method} ${r.path}`)).toEqual([
      "GET /v1/bootstrap",
      "POST /v1/ping",
      "GET /v1/stats",
    ]);
    expect(KEEL_CORE_ROUTES.every((r) => !r.optional)).toBe(true);
  });

  test("bootstrap caches for a minute so the kill switch propagates fast", () => {
    const bootstrap = KEEL_CORE_ROUTES.find((r) => r.path === "/v1/bootstrap");
    expect(bootstrap?.maxAgeSeconds).toBe(60);
  });

  test("ping is never cached", () => {
    const ping = KEEL_CORE_ROUTES.find((r) => r.path === "/v1/ping");
    expect(ping?.maxAgeSeconds).toBeUndefined();
  });

  test("the App Store notification route is optional and verification-only", () => {
    expect(KEEL_APPSTORE_NOTIFICATION_ROUTE.optional).toBe(true);
    expect(`${KEEL_APPSTORE_NOTIFICATION_ROUTE.method} ${KEEL_APPSTORE_NOTIFICATION_ROUTE.path}`)
      .toBe("POST /v1/appstore-notification");
  });

  test("no route path is declared twice", () => {
    const paths = [...KEEL_CORE_ROUTES, KEEL_APPSTORE_NOTIFICATION_ROUTE].map(
      (r) => `${r.method} ${r.path}`,
    );
    expect(new Set(paths).size).toBe(paths.length);
  });

  test("table keys and TTL match the documented schema", () => {
    expect(KEEL_TABLE_KEYS).toEqual({ partitionKey: "pk", sortKey: "sk", timeToLiveAttribute: "ttl" });
    // 400, not 365: a year-over-year comparison needs more than a year of history.
    expect(KEEL_COUNTER_TTL_DAYS).toBe(400);
    expect(KEEL_SCHEMA_VERSION).toBe(1);
  });
});

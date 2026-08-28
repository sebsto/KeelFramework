import {
  KEEL_CORE_ROUTES,
  KEEL_COUNTER_TTL_DAYS,
  KEEL_IAP_ROUTES,
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

  test("every IAP route is optional — an app without purchases mounts none", () => {
    expect(KEEL_IAP_ROUTES.length).toBeGreaterThan(0);
    expect(KEEL_IAP_ROUTES.every((r) => r.optional)).toBe(true);
  });

  test("no route path is declared twice", () => {
    const paths = [...KEEL_CORE_ROUTES, ...KEEL_IAP_ROUTES].map((r) => `${r.method} ${r.path}`);
    expect(new Set(paths).size).toBe(paths.length);
  });

  test("table keys and TTL match the documented schema", () => {
    expect(KEEL_TABLE_KEYS).toEqual({ partitionKey: "pk", sortKey: "sk", timeToLiveAttribute: "ttl" });
    // 400, not 365: a year-over-year comparison needs more than a year of history.
    expect(KEEL_COUNTER_TTL_DAYS).toBe(400);
    expect(KEEL_SCHEMA_VERSION).toBe(1);
  });
});

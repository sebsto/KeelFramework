import { KeelDomainError, normalizeBasePath, validateDomainName } from "../lib";

describe("validateDomainName", () => {
  test("accepts and normalizes a fully-qualified name", () => {
    expect(validateDomainName("api.myapp.com")).toBe("api.myapp.com");
    expect(validateDomainName("API.MyApp.com")).toBe("api.myapp.com");
    expect(validateDomainName("api.myapp.com.")).toBe("api.myapp.com");
    expect(validateDomainName("api.sub.example.co.uk")).toBe("api.sub.example.co.uk");
  });

  test("rejects a URL — the most likely copy-paste mistake", () => {
    expect(() => validateDomainName("https://api.myapp.com")).toThrow(KeelDomainError);
    expect(() => validateDomainName("https://api.myapp.com")).toThrow(/bare hostname/);
  });

  test("rejects a path, pointing at basePath instead", () => {
    expect(() => validateDomainName("api.myapp.com/v1")).toThrow(/must not contain a path/);
  });

  test("rejects a name with no parent domain", () => {
    expect(() => validateDomainName("localhost")).toThrow(/fully qualified/);
  });

  test("rejects a wildcard: API Gateway will not accept one as a custom domain", () => {
    expect(() => validateDomainName("*.myapp.com")).toThrow(/wildcard/);
  });

  test("rejects malformed labels", () => {
    expect(() => validateDomainName("-api.myapp.com")).toThrow(/valid DNS label/);
    expect(() => validateDomainName("api-.myapp.com")).toThrow(/valid DNS label/);
    expect(() => validateDomainName("api..myapp.com")).toThrow(/valid DNS label/);
    expect(() => validateDomainName("under_score.myapp.com")).toThrow(/valid DNS label/);
    expect(() => validateDomainName(`${"a".repeat(64)}.myapp.com`)).toThrow(/valid DNS label/);
  });

  test("accepts a label at the 63-character limit", () => {
    const label = "a".repeat(63);
    expect(validateDomainName(`${label}.myapp.com`)).toBe(`${label}.myapp.com`);
  });

  test("rejects a name over 253 characters", () => {
    const long = `${Array.from({ length: 10 }, () => "a".repeat(25)).join(".")}.com`;
    expect(long.length).toBeGreaterThan(253);
    expect(() => validateDomainName(long)).toThrow(/1-253/);
  });
});

describe("normalizeBasePath", () => {
  test("undefined means mount at the root", () => {
    expect(normalizeBasePath(undefined)).toBeUndefined();
  });

  test('"/" and "" also mean the root — an empty mapping key, not a key of "/"', () => {
    expect(normalizeBasePath("/")).toBeUndefined();
    expect(normalizeBasePath("")).toBeUndefined();
    expect(normalizeBasePath("//")).toBeUndefined();
  });

  test("strips surrounding slashes", () => {
    expect(normalizeBasePath("api")).toBe("api");
    expect(normalizeBasePath("/api")).toBe("api");
    expect(normalizeBasePath("/api/")).toBe("api");
  });

  test("rejects a nested path — API Gateway mapping keys are one segment", () => {
    expect(() => normalizeBasePath("api/v1")).toThrow(/single path segment/);
  });

  test("rejects characters API Gateway will not take", () => {
    expect(() => normalizeBasePath("api v1")).toThrow(KeelDomainError);
    expect(() => normalizeBasePath("api?x=1")).toThrow(KeelDomainError);
  });
});

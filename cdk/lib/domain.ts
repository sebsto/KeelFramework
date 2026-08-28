import type { ICertificate } from "aws-cdk-lib/aws-certificatemanager";

/**
 * Serve the API from a DNS name the app owns.
 *
 * The base URL is compiled into shipped clients, so it is the one thing bootstrap cannot
 * change about an installed app — and AWS's generated hostnames change whenever the
 * underlying resource is replaced. See docs/adr/0007-stable-base-url.md.
 */
export interface KeelDomainOptions {
  /** Fully-qualified name, e.g. `api.myapp.com`. No scheme, no path, no trailing dot. */
  readonly domainName: string;

  /**
   * An **existing** certificate for `domainName`, in the same region as the API.
   *
   * Deliberately not created by the construct: CDK can only auto-validate a DNS-validated
   * certificate when it owns the hosted zone, so with DNS anywhere else the first deploy
   * hangs on a validation record nobody created. Pass a CDK-validated certificate on
   * Route 53, or `Certificate.fromCertificateArn` otherwise.
   *
   * CloudFront needs its certificate in `us-east-1` instead — that path is `KeelStatsSite`,
   * and serving one name both ways needs two certificates.
   */
  readonly certificate: ICertificate;

  /**
   * Mount the API under a path prefix instead of at the root. Omit it — the routes are
   * already versioned (`/v1/…`), and a prefix here means the client's base URL and the
   * server's route table no longer read the same.
   */
  readonly basePath?: string;
}

/** Why a domain name was rejected. Thrown at synth time, never at deploy time. */
export class KeelDomainError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "KeelDomainError";
  }
}

/**
 * Reject a domain name that will fail at deploy time, or produce a certificate mismatch
 * that only shows up as a TLS error from a shipped app.
 *
 * Returns the normalized name (lowercased, trailing dot removed).
 */
export function validateDomainName(domainName: string): string {
  if (/^[a-z]+:\/\//i.test(domainName)) {
    throw new KeelDomainError(
      `domainName must be a bare hostname, not a URL: ${domainName}. ` +
        `Use "api.myapp.com", not "https://api.myapp.com".`,
    );
  }
  if (domainName.includes("/")) {
    throw new KeelDomainError(
      `domainName must not contain a path: ${domainName}. Use basePath for that.`,
    );
  }
  const name = domainName.replace(/\.$/, "").toLowerCase();
  if (name.length === 0 || name.length > 253) {
    throw new KeelDomainError(`domainName must be 1-253 characters: ${domainName}`);
  }
  if (!name.includes(".")) {
    throw new KeelDomainError(
      `domainName must be fully qualified: ${domainName} has no parent domain.`,
    );
  }
  // Checked before the per-label rules below, which would otherwise reject "*" with a
  // misleading message about DNS labels. A wildcard *certificate* is fine and covers
  // `api.myapp.com`; a wildcard custom domain *name* is not — API Gateway rejects it, and it
  // would not say which host the clients actually use.
  if (name.startsWith("*")) {
    throw new KeelDomainError(
      `domainName cannot be a wildcard: ${domainName}. Name the host the clients will use ` +
        `(a wildcard certificate covering it is fine).`,
    );
  }
  for (const label of name.split(".")) {
    if (!/^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/.test(label)) {
      throw new KeelDomainError(
        `"${label}" is not a valid DNS label in ${domainName}. Labels are 1-63 characters ` +
          `of a-z, 0-9 and "-", and cannot start or end with "-".`,
      );
    }
  }
  return name;
}

/**
 * Normalize `basePath` into the form `apigwv2.ApiMapping` wants: no leading or trailing
 * slash, and `undefined` for "mount at the root". An empty mapping key and a key of `"/"`
 * are different things to CloudFormation, and the second one fails.
 */
export function normalizeBasePath(basePath: string | undefined): string | undefined {
  if (basePath === undefined) return undefined;
  const trimmed = basePath.replace(/^\/+/, "").replace(/\/+$/, "");
  if (trimmed.length === 0) return undefined;
  if (trimmed.includes("/")) {
    throw new KeelDomainError(
      `basePath must be a single path segment, got "${basePath}". ` +
        `API Gateway mapping keys cannot be nested.`,
    );
  }
  if (!/^[a-zA-Z0-9._-]+$/.test(trimmed)) {
    throw new KeelDomainError(
      `basePath may only contain letters, digits, ".", "_" and "-", got "${basePath}".`,
    );
  }
  return trimmed;
}

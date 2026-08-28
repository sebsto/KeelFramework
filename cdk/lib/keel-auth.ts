/**
 * The pluggable auth modes for `KeelBackend` — a strategy, not a fork of the construct.
 *
 * Every mode answers the same question: what stands between the internet and the routes
 * that are not in `publicRoutes`? See docs/ARCHITECTURE.md §8 for the mode table.
 */

/** OIDC settings for `KeelAuth.jwt`. */
export interface KeelJwtOptions {
  /** The OIDC issuer URL, e.g. a Cognito user pool's `https://cognito-idp.…` URL. */
  readonly issuer: string;
  /** Accepted `aud` claims — the app client ids. */
  readonly audience: string[];
}

/** Settings for `KeelAuth.sharedSecret`. */
export interface KeelSharedSecretOptions {
  /**
   * Name of an **existing** SSM parameter (SecureString) holding the secret.
   *
   * Existing, because CloudFormation cannot create SecureString parameters — that is an
   * AWS limitation, not a choice — and a secret in a plain String parameter would appear
   * in every `DescribeParameters` and template diff. Create it once:
   *
   * ```
   * aws ssm put-parameter --name /keel/myapp/prod/api-secret \
   *   --type SecureString --value "$(openssl rand -base64 32)"
   * ```
   *
   * Rotation note: the authorizer reads the parameter at cold start and holds it for the
   * life of the execution environment, so after rotating the value, touch the authorizer
   * function (any no-op configuration update) to force fresh cold starts.
   */
  readonly parameterName: string;

  /**
   * Path to the built `KeelAuthorizerLambda` zip. Defaults to the AWSLambdaBuilder
   * plugin's output for the `server` package, same convention as the main function.
   */
  readonly authorizerAssetPath?: string;
}

/**
 * How `KeelBackend` authorizes the routes not listed in `publicRoutes`.
 *
 * Construct one with the static factories; the fields exist for `KeelBackend` to read.
 * The shared secret authenticates the *app*, not a user — every install ships the same
 * value, so treat it as a tripwire against casual abuse, not a security boundary.
 */
export class KeelAuth {
  /** No authorizer anywhere. Everything is public by design (Orthanc's model). */
  static none(): KeelAuth {
    return new KeelAuth("none");
  }

  /**
   * A Lambda authorizer comparing the `Authorization` header against an SSM parameter,
   * in constant time. Casual abuse resistance without accounts (Maxi80's model).
   */
  static sharedSecret(options: KeelSharedSecretOptions): KeelAuth {
    return new KeelAuth("sharedSecret", options);
  }

  /** SigV4 via `AWS_IAM` — for apps whose users already hold AWS credentials (odvpn). */
  static iam(): KeelAuth {
    return new KeelAuth("iam");
  }

  /** API Gateway's built-in JWT authorizer against an OIDC issuer. No Lambda involved. */
  static jwt(options: KeelJwtOptions): KeelAuth {
    return new KeelAuth("jwt", undefined, options);
  }

  private constructor(
    readonly mode: "none" | "sharedSecret" | "iam" | "jwt",
    readonly sharedSecret?: KeelSharedSecretOptions,
    readonly jwt?: KeelJwtOptions,
  ) {}
}

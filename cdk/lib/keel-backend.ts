import * as fs from "node:fs";
import * as path from "node:path";

import * as cdk from "aws-cdk-lib";
import * as apigwv2 from "aws-cdk-lib/aws-apigatewayv2";
import {
  HttpIamAuthorizer,
  HttpJwtAuthorizer,
  HttpLambdaAuthorizer,
  HttpLambdaResponseType,
} from "aws-cdk-lib/aws-apigatewayv2-authorizers";
import { HttpLambdaIntegration } from "aws-cdk-lib/aws-apigatewayv2-integrations";
import * as budgets from "aws-cdk-lib/aws-budgets";
import * as cloudwatch from "aws-cdk-lib/aws-cloudwatch";
import * as dynamodb from "aws-cdk-lib/aws-dynamodb";
import * as iam from "aws-cdk-lib/aws-iam";
import * as lambda from "aws-cdk-lib/aws-lambda";
import * as logs from "aws-cdk-lib/aws-logs";
import { Construct } from "constructs";

import type { KeelRoute } from "./contract";
import { KEEL_APPSTORE_NOTIFICATION_ROUTE, KEEL_CORE_ROUTES, KEEL_TABLE_KEYS } from "./contract";
import type { KeelDomainOptions} from "./domain";
import { normalizeBasePath, validateDomainName } from "./domain";
import { KeelAuth } from "./keel-auth";

/** One alias route declaration, mirrored into the function's `ALIAS_ROUTES` variable. */
export interface KeelAliasRoute {
  /** The canonical route this alias serves. */
  readonly route: "/v1/bootstrap" | "/v1/ping" | "/v1/stats";
  /**
   * `flattened` hoists the `app` payload's keys to the top level — the legacy `/station`
   * shape. Only valid on `/v1/bootstrap`.
   */
  readonly envelope?: "standard" | "flattened";
}

export interface KeelBackendProps {
  /** Short app identifier, used in resource names and defaults. Lowercase. */
  readonly appName: string;

  /** Environment name — `dev`, `staging`, `prod`. Drives data-retention posture. */
  readonly envName: string;

  /**
   * An already-deployed table to use instead of creating one. An app migrating onto Keel
   * imports its live table (`dynamodb.Table.fromTableName/Arn`) and hands it in, so the
   * construct does not create a second one: no orphan table left behind, and the existing
   * `AGG#` history stays where the dashboard already reads it from.
   *
   * The table must carry the contract's key schema (`pk`/`sk`, TTL on `ttl`) — CDK cannot
   * check that for an imported resource. When unset, the construct creates the table as
   * usual. The same least-privilege grants are applied either way.
   */
  readonly existingTable?: dynamodb.ITable;

  /**
   * How non-public routes are authorized. Defaults to `KeelAuth.none()` — an explicit
   * `sharedSecret` default would fail synth for everyone who has not created the SSM
   * parameter yet, which is a worse first-run experience than an open dev API.
   */
  readonly auth?: KeelAuth;

  /**
   * Routes served without authorization, whatever the auth mode. Defaults to
   * `["/v1/stats"]` — the dashboard reads it anonymously, and it holds nothing that
   * is not deliberately published (docs/ARCHITECTURE.md §3).
   */
  readonly publicRoutes?: string[];

  /** Extra paths for the canonical handlers, e.g. `{"/station": {route: "/v1/bootstrap", envelope: "flattened"}}`. */
  readonly aliasRoutes?: Record<string, KeelAliasRoute>;

  /**
   * Path to the built `KeelLambda` zip. Defaults to the AWSLambdaBuilder plugin's output
   * under `lambdaPackagePath`. When the file does not exist yet, a placeholder is
   * deployed and a warning annotated, so `cdk synth` works before the first Swift build.
   */
  readonly lambdaAssetPath?: string;

  /** Root of the Swift server package, for the default asset paths. Default `../server`. */
  readonly lambdaPackagePath?: string;

  /** Serve the API from a DNS name the app owns. See docs/adr/0007-stable-base-url.md. */
  readonly domain?: KeelDomainOptions;

  /**
   * Reserved concurrency for the function. **Opt-in**: a fresh account's limit is 10 and
   * AWS requires ≥10 unreserved, so any reservation is rejected until the limit is
   * raised. The account cap already bounds cost when this is unset.
   */
  readonly reservedConcurrency?: number;

  /**
   * Default-route throttling on the HTTP API's default stage, applied through the stage's
   * `defaultRouteSettings`.
   *
   * Defaults to `{ rateLimit: 20, burstLimit: 40 }`. The ping endpoint is public in every
   * deployment, so some ceiling has to exist, and this one is free: a client pings at most
   * once per UTC day, so 20 requests/sec is orders of magnitude above any honest traffic
   * pattern while still capping a runaway client or a casual flood. Raise it for a
   * genuinely chattier API, lower it to tighten a small deployment.
   */
  readonly throttling?: {
    /** Steady-state requests per second across the stage. */
    readonly rateLimit: number;

    /** Bucket size for bursts above `rateLimit`. */
    readonly burstLimit: number;
  };

  /** Email for a monthly AWS Budgets notification. No budget resource when unset. */
  readonly budgetEmail?: string;

  /** Monthly budget in USD for the `budgetEmail` notification. Default 10. */
  readonly monthlyBudgetUsd?: number;

  /** Seconds the Lambda caches the config item, and the bootstrap `max-age`. Default 60. */
  readonly configTTLSeconds?: number;

  /** Trailing days of DAU in `/v1/stats`. Default 30. */
  readonly dauWindowDays?: number;

  /** Trailing months of MAU in `/v1/stats`. Default 12. */
  readonly mauWindowMonths?: number;

  /** `FEATURE_FLAGS` emergency override, e.g. `"sleep_timer=false"`. Normally unset. */
  readonly featureFlags?: string;

  /**
   * Origins allowed in cross-origin responses. When set, the server echoes the request's
   * `Origin` header back in `Access-Control-Allow-Origin` if it appears in this list, and
   * never emits `*`. Apex and www are distinct entries — list both if the app is reachable
   * under both names. When unset (or empty), no CORS headers are emitted.
   *
   * @example ['https://stormacq.net', 'https://www.stormacq.net']
   */
  readonly allowedOrigins?: string[];

  /** Function log level: trace|debug|info|notice|warning|error|critical. Default info. */
  readonly logLevel?: string;

  /**
   * Mount the App Store server-notification route (verification-only). Off by default; apps
   * without server-side App Store verification get no App Store surface at all.
   * `/v1/appstore-notification` is always public when mounted — Apple's servers hold no
   * credentials of ours, and the JWS verification is the authentication.
   *
   * The framework verifies Apple's JWS and hands the app a verified payload; it does **not**
   * model purchases or entitlements, and never writes a per-user item (there is no
   * `dynamodb:PutItem` grant). What a notification means is the app's business, in its own
   * `builder.mount(appStore:)` handler.
   */
  readonly appStoreNotifications?: KeelAppStoreOptions;
}

/** Settings for `KeelBackendProps.appStoreNotifications`. */
export interface KeelAppStoreOptions {
  /** The app's bundle id, pinned by the JWS verifier against the inner transaction. */
  readonly bundleId: string;

  /**
   * Every product id this backend expects. Wired to the function as `APP_STORE_PRODUCT_IDS`;
   * the ready-made `KeelLambda` rejects a verified notification whose product is not in this
   * list (an app with its own `mount(appStore:)` handler decides for itself).
   */
  readonly productIds: string[];
}

/**
 * The Keel backend: one table, one function, one HTTP API (docs/ARCHITECTURE.md §8).
 *
 * ```ts
 * const backend = new KeelBackend(this, "Backend", {
 *   appName: "myapp",
 *   envName: "prod",
 *   auth: KeelAuth.sharedSecret({ parameterName: "/keel/myapp/prod/api-secret" }),
 *   domain: { domainName: "api.myapp.com", certificate },
 * });
 * ```
 */
export class KeelBackend extends Construct {
  /** `ITable`, not `Table`: with `existingTable` this is an imported reference. */
  readonly table: dynamodb.ITable;
  readonly handler: lambda.Function;
  readonly httpApi: apigwv2.HttpApi;

  /** The URL clients compile in: the custom domain when configured, else the AWS one. */
  readonly apiBaseUrl: string;

  /** CNAME target for an externally-hosted DNS record. Set only with `domain`. */
  readonly regionalDomainName?: string;

  /** API Gateway's hosted zone id, for a Route 53 alias. Set only with `domain`. */
  readonly regionalHostedZoneId?: string;

  constructor(scope: Construct, id: string, props: KeelBackendProps) {
    super(scope, id);

    const isProduction = props.envName === "prod";
    const auth = props.auth ?? KeelAuth.none();
    const publicRoutes = props.publicRoutes ?? ["/v1/stats"];
    const prefix = `${props.appName}-${props.envName}`;

    // --- Table ---
    // A migrating app brings its own table; creating a parallel one would strand its
    // history. Retention posture is the owner's business in that case — CloudFormation
    // does not manage a table it only holds a reference to.
    if (props.existingTable) {
      this.table = props.existingTable;
    } else {
      // No fixed tableName: RETAIN plus a fixed name is the orphan-table trap — a stack
      // deletion or a replacing change leaves a table CloudFormation no longer tracks, and
      // every later deploy fails with "already exists". The name is
      // exported instead, and the function gets it through TABLE_NAME.
      this.table = new dynamodb.Table(this, "Table", {
        partitionKey: { name: KEEL_TABLE_KEYS.partitionKey, type: dynamodb.AttributeType.STRING },
        sortKey: { name: KEEL_TABLE_KEYS.sortKey, type: dynamodb.AttributeType.STRING },
        billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,
        timeToLiveAttribute: KEEL_TABLE_KEYS.timeToLiveAttribute,
        pointInTimeRecoverySpecification: { pointInTimeRecoveryEnabled: isProduction },
        removalPolicy: isProduction ? cdk.RemovalPolicy.RETAIN : cdk.RemovalPolicy.DESTROY,
        deletionProtection: isProduction,
      });
    }

    // --- Function ---
    const packagePath = props.lambdaPackagePath ?? path.join(process.cwd(), "..", "server");
    const logGroup = new logs.LogGroup(this, "Logs", {
      retention: logs.RetentionDays.ONE_MONTH,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    this.handler = new lambda.Function(this, "Function", {
      runtime: lambda.Runtime.PROVIDED_AL2023,
      architecture: lambda.Architecture.ARM_64,
      handler: "bootstrap",
      code: this.lambdaCode(props.lambdaAssetPath, packagePath, "KeelLambda"),
      memorySize: 128,
      timeout: cdk.Duration.seconds(15),
      reservedConcurrentExecutions: props.reservedConcurrency,
      logGroup,
      environment: {
        TABLE_NAME: this.table.tableName,
        CONFIG_TTL_SECONDS: String(props.configTTLSeconds ?? 60),
        DAU_WINDOW_DAYS: String(props.dauWindowDays ?? 30),
        MAU_WINDOW_MONTHS: String(props.mauWindowMonths ?? 12),
        LOG_LEVEL: props.logLevel ?? "info",
        ...(props.featureFlags ? { FEATURE_FLAGS: props.featureFlags } : {}),
        ...aliasRoutesVariable(props.aliasRoutes),
        ...(props.allowedOrigins?.length
          ? { ALLOWED_ORIGINS: props.allowedOrigins.join(",") }
          : {}),
        ...(props.appStoreNotifications
          ? {
              APP_STORE_BUNDLE_ID: props.appStoreNotifications.bundleId,
              APP_STORE_PRODUCT_IDS: props.appStoreNotifications.productIds.join(","),
            }
          : {}),
      },
    });

    // The function's whole vocabulary: atomic ADDs, windowed Queries, and the config item.
    // Deliberately not grantReadWriteData — no Scan, no Delete, no BatchWrite, and no PutItem:
    // the framework verifies App Store notifications but stores nothing per user, so there is
    // no entitlement item to write.
    this.table.grant(
      this.handler,
      "dynamodb:UpdateItem",
      "dynamodb:Query",
      "dynamodb:GetItem",
    );

    // --- HTTP API ---
    this.httpApi = new apigwv2.HttpApi(this, "Api", {
      apiName: prefix,
      description: `Keel backend for ${props.appName} (${props.envName})`,
    });

    const integration = new HttpLambdaIntegration("Handler", this.handler);
    const authorizer = this.authorizer(auth, packagePath);

    const notificationRoute = props.appStoreNotifications
      ? KEEL_APPSTORE_NOTIFICATION_ROUTE
      : undefined;

    // Synth-time guard: the notification route must not collide with a core route. It is only
    // ever mounted unauthenticated (the `isPublic` check below forces it), because Apple cannot
    // present credentials — a path that ended up authorized would silently 401 Apple.
    if (notificationRoute && KEEL_CORE_ROUTES.some((r) => r.path === notificationRoute.path)) {
      throw new Error(
        `appStoreNotifications route ${notificationRoute.path} collides with a core route`,
      );
    }

    const routes: Array<{ path: string; method: apigwv2.HttpMethod }> = [
      ...KEEL_CORE_ROUTES.map((route: KeelRoute) => ({
        path: route.path,
        method: route.method === "GET" ? apigwv2.HttpMethod.GET : apigwv2.HttpMethod.POST,
      })),
      ...(notificationRoute
        ? [
            {
              path: notificationRoute.path,
              method:
                notificationRoute.method === "GET"
                  ? apigwv2.HttpMethod.GET
                  : apigwv2.HttpMethod.POST,
            },
          ]
        : []),
      ...Object.entries(props.aliasRoutes ?? {}).map(([aliasPath, alias]) => ({
        path: aliasPath,
        method: alias.route === "/v1/ping" ? apigwv2.HttpMethod.POST : apigwv2.HttpMethod.GET,
      })),
    ];

    for (const route of routes) {
      // Explicit routes rather than `ANY /{proxy+}`, so `publicRoutes` is expressed in
      // the API's own route table — public means no authorizer attached, not an
      // authorizer that waves it through. An unknown path 404s at the gateway.
      // The notification route is public whatever the mode: Apple cannot authenticate,
      // and the payload's own signature is the boundary.
      const isPublic =
        publicRoutes.includes(route.path) || route.path === "/v1/appstore-notification";
      this.httpApi.addRoutes({
        path: route.path,
        methods: [route.method],
        integration,
        authorizer: isPublic ? undefined : authorizer,
      });
    }

    // OPTIONS preflight routes are registered only when allowedOrigins is set. The Lambda
    // handles the actual CORS check — it echoes the origin only if it is in the allowlist.
    // Preflight routes are always public: the browser sends them without credentials and
    // a 401/403 from the authorizer would block the real request before it starts.
    if (props.allowedOrigins && props.allowedOrigins.length > 0) {
      const corsPaths = new Set([
        ...KEEL_CORE_ROUTES.map((r: KeelRoute) => r.path),
        ...(notificationRoute ? [notificationRoute.path] : []),
        ...Object.keys(props.aliasRoutes ?? {}),
      ]);
      for (const p of corsPaths) {
        this.httpApi.addRoutes({
          path: p,
          methods: [apigwv2.HttpMethod.OPTIONS],
          integration,
          authorizer: undefined,
        });
      }
    }

    // --- Custom domain ---
    if (props.domain) {
      const domainName = new apigwv2.DomainName(this, "Domain", {
        domainName: validateDomainName(props.domain.domainName),
        certificate: props.domain.certificate,
      });
      new apigwv2.ApiMapping(this, "Mapping", {
        api: this.httpApi,
        domainName,
        stage: this.httpApi.defaultStage,
        apiMappingKey: normalizeBasePath(props.domain.basePath),
      });
      this.regionalDomainName = domainName.regionalDomainName;
      this.regionalHostedZoneId = domainName.regionalHostedZoneId;
      this.apiBaseUrl = `https://${props.domain.domainName}`;

      new cdk.CfnOutput(this, "RegionalDomainName", {
        value: domainName.regionalDomainName,
        description: `CNAME target for ${props.domain.domainName} (keep the record DNS-only)`,
      });
      new cdk.CfnOutput(this, "RegionalHostedZoneId", {
        value: domainName.regionalHostedZoneId,
        description: "API Gateway regional hosted zone id, for a Route 53 alias",
      });
    } else {
      this.apiBaseUrl = this.httpApi.apiEndpoint;
      if (isProduction) {
        // The base URL is compiled into shipped clients, and the generated hostname dies
        // with the resource it is derived from. See docs/adr/0007-stable-base-url.md.
        cdk.Annotations.of(this).addWarningV2(
          "keel:prod-without-domain",
          "This is a prod deployment on an AWS-generated hostname. Shipped clients will " +
            "compile it in, and it changes if the API is ever replaced. Configure `domain` " +
            "before the first public release.",
        );
      }
    }

    // --- Throttling ---
    // `/v1/ping` is public in every deployment, so the stage gets a ceiling by default
    // rather than on request. Set through the L1: `HttpStage` does not surface
    // `defaultRouteSettings`, and the default stage is created for us by `HttpApi`.
    const throttling = props.throttling ?? { rateLimit: 20, burstLimit: 40 };
    const cfnStage = this.httpApi.defaultStage!.node.defaultChild as apigwv2.CfnStage;
    cfnStage.defaultRouteSettings = {
      throttlingRateLimit: throttling.rateLimit,
      throttlingBurstLimit: throttling.burstLimit,
    };

    // --- Alarm ---
    new cloudwatch.Alarm(this, "Errors", {
      alarmDescription: `${prefix}: Keel function errors`,
      metric: this.handler.metricErrors({ period: cdk.Duration.minutes(5) }),
      threshold: 1,
      evaluationPeriods: 1,
      treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
    });

    // --- Budget ---
    if (props.budgetEmail) {
      new budgets.CfnBudget(this, "Budget", {
        budget: {
          budgetName: `${prefix}-keel`,
          budgetType: "COST",
          timeUnit: "MONTHLY",
          budgetLimit: { amount: props.monthlyBudgetUsd ?? 10, unit: "USD" },
        },
        notificationsWithSubscribers: [
          {
            notification: {
              notificationType: "ACTUAL",
              comparisonOperator: "GREATER_THAN",
              threshold: 80,
              thresholdType: "PERCENTAGE",
            },
            subscribers: [{ subscriptionType: "EMAIL", address: props.budgetEmail }],
          },
        ],
      });
    }

    new cdk.CfnOutput(this, "ApiBaseUrl", {
      value: this.apiBaseUrl,
      description: "Base URL for the app's KeelConfiguration",
    });
    new cdk.CfnOutput(this, "TableName", {
      value: this.table.tableName,
      description: "Keel table, for `keel config` and `keel stats dump`",
    });
  }

  /** The authorizer for the chosen mode, or undefined for `none`. */
  private authorizer(
    auth: KeelAuth,
    packagePath: string,
  ): apigwv2.IHttpRouteAuthorizer | undefined {
    switch (auth.mode) {
      case "none":
        return undefined;

      case "iam":
        return new HttpIamAuthorizer();

      case "jwt": {
        const jwt = auth.jwt;
        if (!jwt) throw new Error("KeelAuth.jwt requires issuer and audience");
        return new HttpJwtAuthorizer("Jwt", jwt.issuer, {
          jwtAudience: jwt.audience,
        });
      }

      case "sharedSecret": {
        const options = auth.sharedSecret;
        if (!options) throw new Error("KeelAuth.sharedSecret requires a parameterName");

        const authorizerFn = new lambda.Function(this, "Authorizer", {
          runtime: lambda.Runtime.PROVIDED_AL2023,
          architecture: lambda.Architecture.ARM_64,
          handler: "bootstrap",
          code: this.lambdaCode(
            options.authorizerAssetPath,
            packagePath,
            "KeelAuthorizerLambda",
          ),
          memorySize: 128,
          timeout: cdk.Duration.seconds(10),
          environment: { SECRET_PARAMETER: options.parameterName },
          logGroup: new logs.LogGroup(this, "AuthorizerLogs", {
            retention: logs.RetentionDays.ONE_MONTH,
            removalPolicy: cdk.RemovalPolicy.DESTROY,
          }),
        });
        // The parameter is created out-of-band (SecureString is not something
        // CloudFormation can create), so the ARN is constructed by hand rather than
        // imported — `fromStringParameterName` validates the parameter type against
        // CloudFormation's registry and rejects SecureString.
        authorizerFn.addToRolePolicy(
          new iam.PolicyStatement({
            actions: ["ssm:GetParameter"],
            resources: [
              cdk.Stack.of(this).formatArn({
                service: "ssm",
                resource: "parameter",
                resourceName: options.parameterName.replace(/^\//, ""),
              }),
            ],
          }),
        );

        return new HttpLambdaAuthorizer("SharedSecret", authorizerFn, {
          responseTypes: [HttpLambdaResponseType.SIMPLE],
          identitySource: ["$request.header.Authorization"],
          resultsCacheTtl: cdk.Duration.minutes(5),
        });
      }
    }
  }

  /**
   * The function's code: the built zip when it exists, a placeholder otherwise.
   *
   * The placeholder keeps `cdk synth` (and therefore CI template tests) working before
   * the first `swift package archive` run; deploying it produces a function that fails
   * on invoke with an obvious "placeholder" error rather than a mysterious one.
   */
  private lambdaCode(
    explicitPath: string | undefined,
    packagePath: string,
    product: string,
  ): lambda.Code {
    const zipPath =
      explicitPath ??
      path.join(
        packagePath,
        ".build",
        "plugins",
        "AWSLambdaBuilder",
        "outputs",
        "AWSLambdaBuilder",
        product,
        `${product}.zip`,
      );
    if (fs.existsSync(zipPath)) {
      return lambda.Code.fromAsset(zipPath);
    }

    cdk.Annotations.of(this).addWarningV2(
      `keel:placeholder-code-${product}`,
      `${zipPath} does not exist — synthesizing a placeholder for ${product}. ` +
        `Build it with: swift package --package-path ${packagePath} archive`,
    );
    const placeholderDir = fs.mkdtempSync(path.join(cdk.FileSystem.tmpdir, "keel-placeholder-"));
    fs.writeFileSync(
      path.join(placeholderDir, "bootstrap"),
      "#!/bin/sh\necho 'Keel placeholder: build and deploy the real function' >&2\nexit 1\n",
      { mode: 0o755 },
    );
    return lambda.Code.fromAsset(placeholderDir);
  }
}

/** The `ALIAS_ROUTES` variable in the format `AliasRoutes` parses, or nothing. */
function aliasRoutesVariable(
  aliases: Record<string, KeelAliasRoute> | undefined,
): Record<string, string> {
  if (!aliases || Object.keys(aliases).length === 0) return {};
  const entries = Object.entries(aliases).map(([aliasPath, alias]) => {
    if (!aliasPath.startsWith("/") || aliasPath.length < 2) {
      throw new Error(`Alias path must start with "/" and be non-empty, got "${aliasPath}"`);
    }
    const target = alias.route.replace("/v1/", "");
    if (alias.envelope === "flattened" && alias.route !== "/v1/bootstrap") {
      throw new Error(
        `Alias "${aliasPath}": envelope "flattened" is only valid on /v1/bootstrap — ` +
          `nothing else has an app payload to hoist.`,
      );
    }
    return alias.envelope === "flattened" ? `${aliasPath}=${target}.flattened` : `${aliasPath}=${target}`;
  });
  return { ALIAS_ROUTES: entries.join(",") };
}

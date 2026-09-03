import * as fs from "node:fs";

import * as cdk from "aws-cdk-lib";
import { Annotations, Match, Template } from "aws-cdk-lib/assertions";
import * as acm from "aws-cdk-lib/aws-certificatemanager";
import * as dynamodb from "aws-cdk-lib/aws-dynamodb";

import type { KeelBackendProps } from "../lib";
import { KeelAuth, KeelBackend } from "../lib";

function synth(props?: Partial<KeelBackendProps>): {
  template: Template;
  stack: cdk.Stack;
} {
  const app = new cdk.App();
  const stack = new cdk.Stack(app, "Test", {
    env: { account: "123456789012", region: "eu-central-1" },
  });
  new KeelBackend(stack, "Backend", {
    appName: "myapp",
    envName: "dev",
    ...props,
  });
  return { template: Template.fromStack(stack), stack };
}

describe("KeelBackend table", () => {
  test("single table with the contract's key schema, on-demand, TTL on `ttl`", () => {
    const { template } = synth();
    template.resourceCountIs("AWS::DynamoDB::Table", 1);
    template.hasResourceProperties("AWS::DynamoDB::Table", {
      KeySchema: [
        { AttributeName: "pk", KeyType: "HASH" },
        { AttributeName: "sk", KeyType: "RANGE" },
      ],
      BillingMode: "PAY_PER_REQUEST",
      TimeToLiveSpecification: { AttributeName: "ttl", Enabled: true },
    });
  });

  test("no GSI, ever — a GSI on a counter table is a second copy of every write", () => {
    const { template } = synth();
    template.hasResourceProperties("AWS::DynamoDB::Table", {
      GlobalSecondaryIndexes: Match.absent(),
    });
  });

  test("dev: disposable — DESTROY, no PITR, no deletion protection, no fixed name", () => {
    const { template } = synth({ envName: "dev" });
    const tables = template.findResources("AWS::DynamoDB::Table");
    const [table] = Object.values(tables);
    expect(table.DeletionPolicy).toBe("Delete");
    // A fixed TableName is the orphan-table trap; CloudFormation must own the name.
    expect(table.Properties.TableName).toBeUndefined();
    expect(table.Properties.DeletionProtectionEnabled).toBeFalsy();
  });

  test("prod: RETAIN + PITR + deletion protection — counters are unrebuildable", () => {
    const { template } = synth({ envName: "prod" });
    const tables = template.findResources("AWS::DynamoDB::Table");
    const [table] = Object.values(tables);
    expect(table.DeletionPolicy).toBe("Retain");
    expect(table.Properties.DeletionProtectionEnabled).toBe(true);
    expect(
      table.Properties.PointInTimeRecoverySpecification.PointInTimeRecoveryEnabled,
    ).toBe(true);
  });
});

describe("KeelBackend existing table", () => {
  const existingArn = "arn:aws:dynamodb:eu-central-1:123456789012:table/existing-keel";

  function synthWithImportedTable() {
    const app = new cdk.App();
    const stack = new cdk.Stack(app, "Test", {
      env: { account: "123456789012", region: "eu-central-1" },
    });
    const existingTable = dynamodb.Table.fromTableArn(stack, "Imported", existingArn);
    new KeelBackend(stack, "Backend", {
      appName: "myapp",
      envName: "dev",
      existingTable,
    });
    return { template: Template.fromStack(stack), stack };
  }

  test("an imported table means no table is synthesized", () => {
    const { template } = synthWithImportedTable();
    template.resourceCountIs("AWS::DynamoDB::Table", 0);
  });

  test("the same least-privilege grants land on the imported table", () => {
    const { template } = synthWithImportedTable();
    template.hasResourceProperties("AWS::IAM::Policy", {
      PolicyDocument: {
        Statement: Match.arrayWith([
          Match.objectLike({
            Action: ["dynamodb:UpdateItem", "dynamodb:Query", "dynamodb:GetItem"],
            Effect: "Allow",
          }),
        ]),
      },
    });
    // The grant targets the imported ARN, not a CloudFormation-managed one.
    const policies = JSON.stringify(template.findResources("AWS::IAM::Policy"));
    expect(policies).toContain("existing-keel");
    expect(policies).not.toContain("dynamodb:Scan");
  });

  test("without the prop the construct still owns exactly one table", () => {
    const { template } = synth();
    template.resourceCountIs("AWS::DynamoDB::Table", 1);
  });
});

describe("KeelBackend throttling", () => {
  test("the public ping endpoint is throttled by default", () => {
    const { template } = synth();
    template.hasResourceProperties("AWS::ApiGatewayV2::Stage", {
      DefaultRouteSettings: Match.objectLike({
        ThrottlingRateLimit: 20,
        ThrottlingBurstLimit: 40,
      }),
    });
  });

  test("an app can tighten or raise the limits", () => {
    const { template } = synth({ throttling: { rateLimit: 5, burstLimit: 10 } });
    template.hasResourceProperties("AWS::ApiGatewayV2::Stage", {
      DefaultRouteSettings: Match.objectLike({
        ThrottlingRateLimit: 5,
        ThrottlingBurstLimit: 10,
      }),
    });
  });
});

describe("KeelBackend function", () => {
  test("PROVIDED_AL2023 on arm64, 128 MB, 15 s", () => {
    const { template } = synth();
    template.hasResourceProperties("AWS::Lambda::Function", {
      Runtime: "provided.al2023",
      Architectures: ["arm64"],
      MemorySize: 128,
      Timeout: 15,
      Handler: "bootstrap",
    });
  });

  test("environment carries the documented knobs, with TABLE_NAME wired to the table", () => {
    const { template } = synth({
      configTTLSeconds: 120,
      dauWindowDays: 60,
      featureFlags: "sleep_timer=false",
    });
    template.hasResourceProperties("AWS::Lambda::Function", {
      Environment: {
        Variables: Match.objectLike({
          TABLE_NAME: { Ref: Match.stringLikeRegexp("BackendTable") },
          CONFIG_TTL_SECONDS: "120",
          DAU_WINDOW_DAYS: "60",
          MAU_WINDOW_MONTHS: "12",
          FEATURE_FLAGS: "sleep_timer=false",
        }),
      },
    });
  });

  test("alias routes reach the function in the format AliasRoutes parses", () => {
    const { template } = synth({
      aliasRoutes: {
        "/station": { route: "/v1/bootstrap", envelope: "flattened" },
        "/usage": { route: "/v1/stats" },
      },
    });
    template.hasResourceProperties("AWS::Lambda::Function", {
      Environment: {
        Variables: Match.objectLike({
          ALIAS_ROUTES: "/station=bootstrap.flattened,/usage=stats",
        }),
      },
    });
  });

  test("a flattened alias on anything but bootstrap fails at synth", () => {
    expect(() =>
      synth({ aliasRoutes: { "/usage": { route: "/v1/stats", envelope: "flattened" } } }),
    ).toThrow(/only valid on \/v1\/bootstrap/);
  });

  test("table permissions are the three calls the code makes, not ReadWrite", () => {
    const { template } = synth();
    template.hasResourceProperties("AWS::IAM::Policy", {
      PolicyDocument: {
        Statement: Match.arrayWith([
          Match.objectLike({
            Action: ["dynamodb:UpdateItem", "dynamodb:Query", "dynamodb:GetItem"],
            Effect: "Allow",
          }),
        ]),
      },
    });
    // No Scan anywhere: the schema is built so no read path needs one.
    const policies = JSON.stringify(template.findResources("AWS::IAM::Policy"));
    expect(policies).not.toContain("dynamodb:Scan");
  });

  test("reserved concurrency is opt-in only", () => {
    const { template } = synth();
    template.hasResourceProperties("AWS::Lambda::Function", {
      ReservedConcurrentExecutions: Match.absent(),
    });

    const { template: reserved } = synth({ reservedConcurrency: 10 });
    reserved.hasResourceProperties("AWS::Lambda::Function", {
      ReservedConcurrentExecutions: 10,
    });
  });

  test("synth works before the first Swift build, with a placeholder warning", () => {
    // A package path with no built zip, whatever the local build state is.
    const { stack } = synth({ lambdaPackagePath: "/nonexistent-swift-package" });
    Annotations.fromStack(stack).hasWarning(
      "*",
      Match.stringLikeRegexp("placeholder"),
    );
  });

  test("a built zip is used as-is, no placeholder warning", () => {
    const { stack } = synth();
    // This assertion is environment-aware on purpose: once `make lambda` has produced
    // the real zips, the placeholder path must NOT be taken.
    const zip =
      "../server/.build/plugins/AWSLambdaBuilder/outputs/AWSLambdaBuilder/KeelLambda/KeelLambda.zip";
    if (fs.existsSync(zip)) {
      const warnings = Annotations.fromStack(stack).findWarning(
        "*",
        Match.stringLikeRegexp("placeholder"),
      );
      expect(warnings).toHaveLength(0);
    }
  });
});

describe("KeelBackend routes and auth", () => {
  test("the three canonical routes exist as explicit routes", () => {
    const { template } = synth();
    for (const key of ["GET /v1/bootstrap", "POST /v1/ping", "GET /v1/stats"]) {
      template.hasResourceProperties("AWS::ApiGatewayV2::Route", { RouteKey: key });
    }
  });

  test("alias routes take the method of their target", () => {
    const { template } = synth({
      aliasRoutes: {
        "/station": { route: "/v1/bootstrap", envelope: "flattened" },
        "/legacy-ping": { route: "/v1/ping" },
      },
    });
    template.hasResourceProperties("AWS::ApiGatewayV2::Route", {
      RouteKey: "GET /station",
    });
    template.hasResourceProperties("AWS::ApiGatewayV2::Route", {
      RouteKey: "POST /legacy-ping",
    });
  });

  test("auth none: no authorizer resources, every route open", () => {
    const { template } = synth({ auth: KeelAuth.none() });
    template.resourceCountIs("AWS::ApiGatewayV2::Authorizer", 0);
    const routes = Object.values(template.findResources("AWS::ApiGatewayV2::Route"));
    for (const route of routes) {
      expect(route.Properties.AuthorizationType ?? "NONE").toBe("NONE");
    }
  });

  test("auth sharedSecret: authorizer Lambda, SSM grant, public routes exempt", () => {
    const { template } = synth({
      auth: KeelAuth.sharedSecret({ parameterName: "/keel/myapp/dev/api-secret" }),
      publicRoutes: ["/v1/stats", "/v1/bootstrap"],
    });

    template.resourceCountIs("AWS::ApiGatewayV2::Authorizer", 1);
    template.hasResourceProperties("AWS::ApiGatewayV2::Authorizer", {
      AuthorizerType: "REQUEST",
      AuthorizerPayloadFormatVersion: "2.0",
      EnableSimpleResponses: true,
      IdentitySource: ["$request.header.Authorization"],
    });

    // The authorizer function reads exactly one parameter.
    template.hasResourceProperties("AWS::IAM::Policy", {
      PolicyDocument: {
        Statement: Match.arrayWith([
          Match.objectLike({ Action: "ssm:GetParameter" }),
        ]),
      },
    });
    template.hasResourceProperties("AWS::Lambda::Function", {
      Environment: {
        Variables: Match.objectLike({
          SECRET_PARAMETER: "/keel/myapp/dev/api-secret",
        }),
      },
    });

    // Ping is authorized; stats and bootstrap are not.
    const routes = Object.values(template.findResources("AWS::ApiGatewayV2::Route"));
    const byKey = Object.fromEntries(routes.map((r) => [r.Properties.RouteKey, r.Properties]));
    expect(byKey["POST /v1/ping"].AuthorizationType).toBe("CUSTOM");
    expect(byKey["GET /v1/stats"].AuthorizationType ?? "NONE").toBe("NONE");
    expect(byKey["GET /v1/bootstrap"].AuthorizationType ?? "NONE").toBe("NONE");
  });

  test("auth iam: SigV4 on non-public routes, no authorizer resource", () => {
    const { template } = synth({ auth: KeelAuth.iam() });
    template.resourceCountIs("AWS::ApiGatewayV2::Authorizer", 0);
    const routes = Object.values(template.findResources("AWS::ApiGatewayV2::Route"));
    const byKey = Object.fromEntries(routes.map((r) => [r.Properties.RouteKey, r.Properties]));
    expect(byKey["POST /v1/ping"].AuthorizationType).toBe("AWS_IAM");
    expect(byKey["GET /v1/stats"].AuthorizationType ?? "NONE").toBe("NONE");
  });

  test("auth jwt: an API Gateway JWT authorizer, no Lambda", () => {
    const { template } = synth({
      auth: KeelAuth.jwt({
        issuer: "https://cognito-idp.eu-central-1.amazonaws.com/eu-central-1_abc",
        audience: ["client-id"],
      }),
    });
    template.hasResourceProperties("AWS::ApiGatewayV2::Authorizer", {
      AuthorizerType: "JWT",
      JwtConfiguration: {
        Audience: ["client-id"],
        Issuer: "https://cognito-idp.eu-central-1.amazonaws.com/eu-central-1_abc",
      },
    });
  });

  test("stats is public by default — the dashboard reads it anonymously", () => {
    const { template } = synth({ auth: KeelAuth.iam() });
    const routes = Object.values(template.findResources("AWS::ApiGatewayV2::Route"));
    const stats = routes.find((r) => r.Properties.RouteKey === "GET /v1/stats");
    expect(stats?.Properties.AuthorizationType ?? "NONE").toBe("NONE");
  });
});

describe("KeelBackend domain", () => {
  function synthWithDomain(envName: string) {
    const app = new cdk.App();
    const stack = new cdk.Stack(app, "Test", {
      env: { account: "123456789012", region: "eu-central-1" },
    });
    const certificate = acm.Certificate.fromCertificateArn(
      stack,
      "Cert",
      "arn:aws:acm:eu-central-1:123456789012:certificate/abc",
    );
    new KeelBackend(stack, "Backend", {
      appName: "myapp",
      envName,
      domain: { domainName: "api.myapp.com", certificate },
    });
    return { template: Template.fromStack(stack), stack };
  }

  test("domain creates the DomainName and a root mapping on $default", () => {
    const { template } = synthWithDomain("prod");
    template.hasResourceProperties("AWS::ApiGatewayV2::DomainName", {
      DomainName: "api.myapp.com",
    });
    template.hasResourceProperties("AWS::ApiGatewayV2::ApiMapping", {
      // No ApiMappingKey: a key would make API Gateway strip the prefix and /v1 would
      // stop resolving.
      ApiMappingKey: Match.absent(),
    });
  });

  test("prod without a domain warns; dev does not", () => {
    const { stack: prod } = synth({ envName: "prod" });
    Annotations.fromStack(prod).hasWarning(
      "*",
      Match.stringLikeRegexp("prod deployment on an AWS-generated hostname"),
    );

    const { stack: dev } = synth({ envName: "dev" });
    const warnings = Annotations.fromStack(dev).findWarning(
      "*",
      Match.stringLikeRegexp("AWS-generated hostname"),
    );
    expect(warnings).toHaveLength(0);
  });

  test("with a domain, prod synthesizes without the hostname warning", () => {
    const { stack } = synthWithDomain("prod");
    const warnings = Annotations.fromStack(stack).findWarning(
      "*",
      Match.stringLikeRegexp("AWS-generated hostname"),
    );
    expect(warnings).toHaveLength(0);
  });
});

describe("KeelBackend operations", () => {
  test("an error alarm on the function", () => {
    const { template } = synth();
    template.hasResourceProperties("AWS::CloudWatch::Alarm", {
      MetricName: "Errors",
      Namespace: "AWS/Lambda",
      Threshold: 1,
    });
  });

  test("a budget only when an email is given", () => {
    const { template } = synth();
    template.resourceCountIs("AWS::Budgets::Budget", 0);

    const { template: withBudget } = synth({ budgetEmail: "me@example.com" });
    withBudget.hasResourceProperties("AWS::Budgets::Budget", {
      Budget: Match.objectLike({
        BudgetLimit: { Amount: 10, Unit: "USD" },
      }),
      NotificationsWithSubscribers: [
        Match.objectLike({
          Subscribers: [{ SubscriptionType: "EMAIL", Address: "me@example.com" }],
        }),
      ],
    });
  });

  test("log groups have retention — Lambda's default is never-expire", () => {
    const { template } = synth();
    template.hasResourceProperties("AWS::Logs::LogGroup", {
      RetentionInDays: 30,
    });
  });
});

describe("KeelBackend IAP", () => {
  const iap = { bundleId: "com.example.app", productIds: ["unlock_pro", "sub_monthly"] };

  test("no IAP surface at all unless opted in", () => {
    const { template } = synth();
    const routes = Object.values(template.findResources("AWS::ApiGatewayV2::Route"));
    expect(routes.some((r) => String(r.Properties.RouteKey).includes("purchase"))).toBe(false);
    const policies = JSON.stringify(template.findResources("AWS::IAM::Policy"));
    expect(policies).not.toContain("dynamodb:PutItem");
  });

  test("opting in mounts the three routes and passes the identity to the function", () => {
    const { template } = synth({ iap });
    for (const key of [
      "POST /v1/purchase",
      "GET /v1/entitlement",
      "POST /v1/appstore-notification",
    ]) {
      template.hasResourceProperties("AWS::ApiGatewayV2::Route", { RouteKey: key });
    }
    template.hasResourceProperties("AWS::Lambda::Function", {
      Environment: {
        Variables: Match.objectLike({
          IAP_BUNDLE_ID: "com.example.app",
          IAP_PRODUCT_IDS: "unlock_pro,sub_monthly",
        }),
      },
    });
  });

  test("entitlement writes get PutItem, and only then", () => {
    const { template } = synth({ iap });
    template.hasResourceProperties("AWS::IAM::Policy", {
      PolicyDocument: {
        Statement: Match.arrayWith([
          Match.objectLike({
            Action: Match.arrayWith(["dynamodb:PutItem"]),
          }),
        ]),
      },
    });
  });

  test("the notification route stays public even under an auth mode", () => {
    const { template } = synth({
      iap,
      auth: KeelAuth.iam(),
    });
    const routes = Object.values(template.findResources("AWS::ApiGatewayV2::Route"));
    const byKey = Object.fromEntries(routes.map((r) => [r.Properties.RouteKey, r.Properties]));
    // Apple cannot present credentials; the JWS signature is the boundary.
    expect(byKey["POST /v1/appstore-notification"].AuthorizationType ?? "NONE").toBe("NONE");
    // The user-facing IAP routes are authorized like everything else.
    expect(byKey["POST /v1/purchase"].AuthorizationType).toBe("AWS_IAM");
    expect(byKey["GET /v1/entitlement"].AuthorizationType).toBe("AWS_IAM");
  });
});

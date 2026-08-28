/**
 * A minimal app for the `cdk synth` smoke test — proves every auth mode actually
 * synthesizes outside jest:
 *
 * ```
 * npx cdk --app "npx tsx test/synth-app.ts" synth -c auth=sharedSecret
 * ```
 */
import * as cdk from "aws-cdk-lib";
import * as acm from "aws-cdk-lib/aws-certificatemanager";

import { KeelAuth, KeelBackend, KeelStatsSite } from "../lib";

const app = new cdk.App();
const stack = new cdk.Stack(app, "KeelSynthSmokeTest", {
  env: { account: "123456789012", region: "eu-central-1" },
});

const mode = (app.node.tryGetContext("auth") as string | undefined) ?? "none";
const auth = (() => {
  switch (mode) {
    case "none":
      return KeelAuth.none();
    case "sharedSecret":
      return KeelAuth.sharedSecret({ parameterName: "/keel/demo/dev/api-secret" });
    case "iam":
      return KeelAuth.iam();
    case "jwt":
      return KeelAuth.jwt({
        issuer: "https://cognito-idp.eu-central-1.amazonaws.com/eu-central-1_demo",
        audience: ["demo-client"],
      });
    default:
      throw new Error(`Unknown auth mode "${mode}"`);
  }
})();

const backend = new KeelBackend(stack, "Backend", {
  appName: "demo",
  envName: "dev",
  auth,
  aliasRoutes: { "/station": { route: "/v1/bootstrap", envelope: "flattened" } },
  budgetEmail: "ops@example.com",
});

new KeelStatsSite(stack, "Stats", { api: backend.httpApi });

if (app.node.tryGetContext("withDomain") === "true") {
  new KeelBackend(stack, "DomainBackend", {
    appName: "demo2",
    envName: "prod",
    domain: {
      domainName: "api.demo.example.com",
      certificate: acm.Certificate.fromCertificateArn(
        stack,
        "Cert",
        "arn:aws:acm:eu-central-1:123456789012:certificate/demo",
      ),
    },
  });
}

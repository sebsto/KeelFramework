import * as cdk from "aws-cdk-lib";
import { KeelAuth, KeelBackend, KeelStatsSite } from "@keel/cdk";
import type { Construct } from "constructs";

export interface SampleAppStackProps extends cdk.StackProps {
  /** `dev` or `prod` — drives the table's retention posture. */
  readonly envName: string;
}

/**
 * The whole backend of a Keel app: one construct, one optional dashboard.
 *
 * Things to change when you adopt this:
 * - `appName`, and the SSM parameter name if you switch auth to `sharedSecret`.
 * - `domain` before the first public release — the warning `cdk synth` prints for a
 *   prod deploy without one is not decorative (docs/adr/0007-stable-base-url.md).
 * - `iap` if the app sells anything (and then create the products in App Store Connect
 *   and point its server notification URL at `/v1/appstore-notification`).
 */
export class SampleAppStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: SampleAppStackProps) {
    super(scope, id, props);

    const backend = new KeelBackend(this, "Backend", {
      appName: "sampleapp",
      envName: props.envName,
      // Everything public: the simplest start. Move to sharedSecret before shipping:
      //   aws ssm put-parameter --name /keel/sampleapp/prod/api-secret \
      //     --type SecureString --value "$(openssl rand -base64 32)"
      //   auth: KeelAuth.sharedSecret({ parameterName: "/keel/sampleapp/prod/api-secret" }),
      auth: KeelAuth.none(),
      // auth: KeelAuth.sharedSecret({ parameterName: "/keel/sampleapp/dev/api-secret" }),
      // auth: KeelAuth.iam(),
      lambdaPackagePath: "../../../server",
      budgetEmail: process.env.KEEL_BUDGET_EMAIL,
    });

    new KeelStatsSite(this, "Stats", {
      api: backend.httpApi,
      dashboardPath: "../../../dashboard",
    });
  }
}

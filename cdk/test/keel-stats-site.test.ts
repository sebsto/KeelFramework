import * as cdk from "aws-cdk-lib";
import { Annotations, Match, Template } from "aws-cdk-lib/assertions";
import * as acm from "aws-cdk-lib/aws-certificatemanager";

import { KeelBackend, KeelStatsSite } from "../lib";

function synthSite(props?: { domainName?: string; withCertificate?: boolean }) {
  const app = new cdk.App();
  const stack = new cdk.Stack(app, "Test", {
    env: { account: "123456789012", region: "us-east-1" },
  });
  const backend = new KeelBackend(stack, "Backend", { appName: "myapp", envName: "dev" });
  new KeelStatsSite(stack, "Stats", {
    api: backend.httpApi,
    dashboardPath: "/nonexistent-on-purpose",
    ...(props?.domainName ? { domainName: props.domainName } : {}),
    ...(props?.withCertificate
      ? {
          certificate: acm.Certificate.fromCertificateArn(
            stack,
            "Cert",
            "arn:aws:acm:us-east-1:123456789012:certificate/abc",
          ),
        }
      : {}),
  });
  return { template: Template.fromStack(stack), stack };
}

describe("KeelStatsSite", () => {
  test("private bucket behind OAC — never website hosting", () => {
    const { template } = synthSite();
    template.hasResourceProperties("AWS::S3::Bucket", {
      PublicAccessBlockConfiguration: Match.objectLike({
        BlockPublicAcls: true,
        BlockPublicPolicy: true,
      }),
      WebsiteConfiguration: Match.absent(),
    });
    template.resourceCountIs("AWS::CloudFront::OriginAccessControl", 1);
  });

  test("/v1/* forwards to the API and caches on the origin's own Cache-Control", () => {
    const { template } = synthSite();
    template.hasResourceProperties("AWS::CloudFront::Distribution", {
      DistributionConfig: Match.objectLike({
        CacheBehaviors: [
          Match.objectLike({
            PathPattern: "/v1/*",
            ViewerProtocolPolicy: "https-only",
            // A custom cache policy (no Host header) rather than the managed
            // UseOriginCacheControlHeaders-QueryStrings, which includes Host and
            // breaks API Gateway v2 HTTP APIs behind CloudFront.
            CachePolicyId: Match.objectLike({ Ref: Match.anyValue() }),
          }),
        ],
      }),
    });
    // The custom policy must exist and must NOT include Host.
    template.hasResourceProperties("AWS::CloudFront::CachePolicy", {
      CachePolicyConfig: Match.objectLike({
        ParametersInCacheKeyAndForwardedToOrigin: Match.objectLike({
          HeadersConfig: Match.objectLike({
            HeaderBehavior: "whitelist",
            Headers: Match.not(Match.arrayWith(["Host"])),
          }),
        }),
      }),
    });
  });

  test("default behavior serves the bucket over HTTPS", () => {
    const { template } = synthSite();
    template.hasResourceProperties("AWS::CloudFront::Distribution", {
      DistributionConfig: Match.objectLike({
        DefaultRootObject: "index.html",
        DefaultCacheBehavior: Match.objectLike({
          ViewerProtocolPolicy: "redirect-to-https",
        }),
      }),
    });
  });

  test("a custom domain rides the distribution when both name and cert are given", () => {
    const { template } = synthSite({ domainName: "stats.myapp.com", withCertificate: true });
    template.hasResourceProperties("AWS::CloudFront::Distribution", {
      DistributionConfig: Match.objectLike({
        Aliases: ["stats.myapp.com"],
      }),
    });
  });

  test("a domain without a certificate is rejected at synth", () => {
    expect(() => synthSite({ domainName: "stats.myapp.com" })).toThrow(/both or neither/);
  });

  test("a missing dashboard directory warns instead of failing synth", () => {
    const { stack } = synthSite();
    Annotations.fromStack(stack).hasWarning("*", Match.stringLikeRegexp("dashboard"));
  });
});

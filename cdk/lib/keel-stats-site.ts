import * as fs from "node:fs";

import * as cdk from "aws-cdk-lib";
import type * as apigwv2 from "aws-cdk-lib/aws-apigatewayv2";
import type { ICertificate } from "aws-cdk-lib/aws-certificatemanager";
import * as cloudfront from "aws-cdk-lib/aws-cloudfront";
import * as origins from "aws-cdk-lib/aws-cloudfront-origins";
import * as s3 from "aws-cdk-lib/aws-s3";
import * as s3deploy from "aws-cdk-lib/aws-s3-deployment";
import { Construct } from "constructs";

import { validateDomainName } from "./domain";

export interface KeelStatsSiteProps {
  /** The Keel HTTP API — `backend.httpApi`. */
  readonly api: apigwv2.HttpApi;

  /**
   * Directory of static dashboard files to deploy. Defaults to Keel's own
   * `dashboard/` template; point it at your fork once you restyle it. When the
   * directory does not exist, the deployment is skipped with a warning so synth
   * still works.
   */
  readonly dashboardPath?: string;

  /** Serve the site from a name you own, e.g. `stats.myapp.com`. */
  readonly domainName?: string;

  /**
   * Certificate for `domainName` — **must be in us-east-1**, CloudFront's rule,
   * regardless of where this stack deploys. A second certificate even if the API
   * domain already has one in the API's region.
   */
  readonly certificate?: ICertificate;
}

/**
 * The stats dashboard: S3 behind CloudFront, with `/v1/*` forwarded to the API so the
 * page and its data are same-origin — no CORS, and `/v1/stats` gets edge-cached for the
 * `max-age=300` the Lambda sends (docs/ARCHITECTURE.md §8).
 */
export class KeelStatsSite extends Construct {
  readonly bucket: s3.Bucket;
  readonly distribution: cloudfront.Distribution;

  constructor(scope: Construct, id: string, props: KeelStatsSiteProps) {
    super(scope, id);

    if (Boolean(props.domainName) !== Boolean(props.certificate)) {
      throw new Error("domainName and certificate come together — pass both or neither.");
    }

    // Private bucket; CloudFront reaches it through Origin Access Control. Never
    // website-hosting mode, which would require the bucket to be public.
    this.bucket = new s3.Bucket(this, "Site", {
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      encryption: s3.BucketEncryption.S3_MANAGED,
      enforceSSL: true,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
      autoDeleteObjects: true,
    });

    // The API origin is the bare execute-api hostname, split out of the endpoint URL.
    const apiDomain = cdk.Fn.select(2, cdk.Fn.split("/", props.api.apiEndpoint));

    this.distribution = new cloudfront.Distribution(this, "Distribution", {
      comment: "Keel stats dashboard",
      defaultRootObject: "index.html",
      defaultBehavior: {
        origin: origins.S3BucketOrigin.withOriginAccessControl(this.bucket),
        viewerProtocolPolicy: cloudfront.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
        cachePolicy: cloudfront.CachePolicy.CACHING_OPTIMIZED,
      },
      additionalBehaviors: {
        "/v1/*": {
          origin: new origins.HttpOrigin(apiDomain),
          viewerProtocolPolicy: cloudfront.ViewerProtocolPolicy.HTTPS_ONLY,
          allowedMethods: cloudfront.AllowedMethods.ALLOW_ALL,
          // A custom cache policy that mirrors the managed
          // UseOriginCacheControlHeaders-QueryStrings *without* the Host header.
          // The managed policy includes Host, which breaks API Gateway v2 HTTP
          // APIs behind CloudFront — APIGW returns 403 Forbidden when the Host
          // doesn't match its own execute-api domain.
          cachePolicy: new cloudfront.CachePolicy(this, "ApiCachePolicy", {
            cachePolicyName: `${cdk.Names.uniqueId(this)}-ApiOriginCache`,
            comment: "Origin Cache-Control + query strings, no Host (APIGW v2 compat)",
            defaultTtl: cdk.Duration.seconds(0),
            minTtl: cdk.Duration.seconds(0),
            maxTtl: cdk.Duration.days(365),
            headerBehavior: cloudfront.CacheHeaderBehavior.allowList(
              "Origin", "X-HTTP-Method", "X-HTTP-Method-Override", "X-Method-Override",
            ),
            queryStringBehavior: cloudfront.CacheQueryStringBehavior.all(),
            cookieBehavior: cloudfront.CacheCookieBehavior.all(),
            enableAcceptEncodingGzip: true,
            enableAcceptEncodingBrotli: true,
          }),
          originRequestPolicy: cloudfront.OriginRequestPolicy.ALL_VIEWER_EXCEPT_HOST_HEADER,
        },
      },
      ...(props.domainName && props.certificate
        ? {
            domainNames: [validateDomainName(props.domainName)],
            certificate: props.certificate,
          }
        : {}),
      priceClass: cloudfront.PriceClass.PRICE_CLASS_100,
    });

    const dashboardPath = props.dashboardPath ?? "../dashboard";
    if (fs.existsSync(dashboardPath) && fs.readdirSync(dashboardPath).length > 0) {
      new s3deploy.BucketDeployment(this, "Deploy", {
        sources: [s3deploy.Source.asset(dashboardPath)],
        destinationBucket: this.bucket,
        distribution: this.distribution,
        distributionPaths: ["/*"],
      });
    } else {
      cdk.Annotations.of(this).addWarningV2(
        "keel:no-dashboard-files",
        `${dashboardPath} is empty or missing — the distribution will serve 404s until ` +
          `dashboard files are deployed.`,
      );
    }

    new cdk.CfnOutput(this, "SiteUrl", {
      value: props.domainName
        ? `https://${props.domainName}`
        : `https://${this.distribution.distributionDomainName}`,
      description: "Stats dashboard URL",
    });
    if (props.domainName) {
      new cdk.CfnOutput(this, "DistributionDomainName", {
        value: this.distribution.distributionDomainName,
        description: `CNAME target for ${props.domainName} (keep the record DNS-only)`,
      });
    }
  }
}

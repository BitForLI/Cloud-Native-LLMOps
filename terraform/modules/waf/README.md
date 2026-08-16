# Regional AWS WAF boundary

Associates a regional Web ACL with the public Application Load Balancer. The
ACL blocks excessive requests from one source IP and uses AWS-managed IP
reputation, known-bad-input, and common-threat rule groups.

Request sampling is disabled. CloudWatch logging keeps blocked requests only
and redacts `Authorization`, `X-API-Key`, and query strings. A five-minute
blocked-request alarm reuses the platform SNS notification path.

Each environment owns a source-account/source-ARN-scoped CloudWatch Logs
resource policy instead of allowing WAF to expand a generic account policy.

Development can disable this paid boundary. Staging and production compose the
module unconditionally so their public ALBs cannot be applied without WAF.

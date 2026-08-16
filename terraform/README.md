# Terraform infrastructure

`modules/` contains reusable infrastructure components; `environments/`
composes them without copying resource definitions. The development root now
creates the foundation needed by later ECS work:

- one VPC with DNS enabled;
- public and private subnet tiers across two or three availability zones;
- an internet gateway and isolated route table per private subnet;
- configurable `none`, `single`, or `per_az` NAT topology;
- an S3 gateway endpoint on private routes;
- separate encrypted, scan-on-push, immutable ECR repositories for API and Worker;
- ECR lifecycle policies for untagged and excess images.
- a private, versioned, TLS-only S3 artifact bucket with lifecycle controls;
- an encrypted on-demand DynamoDB job table with TTL and point-in-time recovery;
- an encrypted long-poll SQS inference queue with bounded retries and a DLQ.
- separate least-privilege ECS execution, API, Worker, and GitHub deploy roles;
- GitHub OIDC federation restricted to exact immutable repository subjects.
- an internet-facing ALB with private IP targets and optional HTTPS redirect;
- hardened API and Worker Fargate tasks with retained CloudWatch logs;
- ECS rolling-deployment circuit breakers with automatic rollback.
- a CloudWatch operations dashboard, structured-log metric filters, and SLO alarms;
- a customer-KMS-encrypted SNS topic with optional confirmed email notifications.
- an empty Secrets Manager API-token container encrypted by a rotating customer KMS key.
- a pinned ADOT Collector sidecar per task exporting OTLP traces to AWS X-Ray.
- ECS Application Auto Scaling with bounded API utilization and Worker queue-pressure policies.
- regional AWS WAF managed rules, per-IP throttling, redacted blocked-request logs, and alarms.
- a customer-KMS-encrypted AWS Backup vault with governance retention lock;
- daily/weekly S3 and DynamoDB snapshots plus monthly automated restore tests.
- an exact-subject, read-only production incident-diagnostics OIDC role.

The dev default uses one NAT gateway to control cost. Production should use
`per_az` for zone-independent egress. NAT gateways incur hourly and data
processing charges; `none` is useful only after all required private endpoints
exist.

## Validate locally

Install Terraform `1.10+`, then run:

```bash
terraform fmt -check -recursive terraform
terraform -chdir=terraform/environments/dev init -backend=false -lockfile=readonly
terraform -chdir=terraform/environments/dev validate
terraform -chdir=terraform/environments/dev test
terraform -chdir=terraform/environments/staging init -backend=false -lockfile=readonly
terraform -chdir=terraform/environments/staging validate
terraform -chdir=terraform/environments/staging test
terraform -chdir=terraform/environments/production init -backend=false -lockfile=readonly
terraform -chdir=terraform/environments/production validate
terraform -chdir=terraform/environments/production test
```

Copy `terraform.tfvars.example` when values must differ. Do not commit real
credentials, `.tfstate`, or a populated backend file.

## Remote state

State infrastructure must exist before this stack. Copy
`backend.s3.tfbackend.example` outside version control, replace its bucket, and
initialize with:

```bash
terraform -chdir=terraform/environments/dev init \
  -backend-config=/secure/path/dev.s3.tfbackend
```

The S3 backend uses native lockfiles and encryption. AWS credentials come from
the standard provider chain locally and from GitHub OIDC in CI/CD; static access
keys do not belong in Terraform files.

## Durable job boundary

Infrastructure now exposes the SQS queue URL, DynamoDB table name, and S3
bucket name required by the distributed API/Worker adapters. ECS selects the
AWS backend explicitly: the API creates and reads job state, then publishes SQS
work; the Worker long-polls, invokes Bedrock, conditionally writes the result,
and acknowledges only successful or already-successful deliveries. Transient
failures retry, poison messages remain in the DLQ for 14 days, and prompts are
never written to DynamoDB or logs.

## IAM boundaries

The API can submit SQS messages but cannot consume them; the Worker can consume
and delete messages but cannot submit them. Bedrock access is limited to the
configured model, data access is limited to this stack's S3/DynamoDB resources,
and GitHub can push only to the two service repositories, update the two ECS
services, and pass only the three platform roles.

The development trust uses GitHub's immutable subject for repository ID
`1320235086` under owner ID `218609705`, restricted to `master`. If an account
already has the account-wide GitHub OIDC provider, set
`github_oidc_provider_arn` instead of attempting to create a duplicate.

## ECS bootstrap

The ECS services run only in private subnets, receive no public IP addresses,
run as UID/GID `10001`, use read-only root filesystems plus writable `/tmp`, and
publish logs to `/ecs/<stack>/api|worker`. The ALB is the only source permitted
to reach API port `8000`; tasks have outbound HTTPS for AWS APIs. Because
Fargate does not support Docker `tmpfs`, each read-only container receives a
writable task-ephemeral bind mount at `/tmp`.

ECR repositories are immutable and intentionally reject `latest`. Before the
first ECS apply, build and push both images using the tags supplied in
`api_image_tag` and `worker_image_tag` (the dev example uses `bootstrap`). A
certificate enables HTTPS with automatic HTTP redirect; certificate-free dev
uses HTTP and must not be treated as a production endpoint.

For a new account, bootstrap the repositories and secret before the full stack:

```bash
terraform -chdir=terraform/environments/dev apply \
  -target=module.api_ecr -target=module.worker_ecr -target=module.secrets
# authenticate Docker, then build and push API and Worker with the bootstrap tag
API_AUTH_TOKEN="$(openssl rand -hex 32)"
aws secretsmanager put-secret-value \
  --secret-id "$(terraform -chdir=terraform/environments/dev output -raw api_auth_secret_name)" \
  --secret-string "$API_AUTH_TOKEN"
unset API_AUTH_TOKEN
terraform -chdir=terraform/environments/dev apply
```

Repeat the secret bootstrap independently in every environment. Rotating the
value creates a new `AWSCURRENT` version; force a new API deployment afterward
because ECS resolves injected secrets only when a task starts.

This stage uses ECS rolling deployments with deployment circuit breakers and
rollback. CodeDeploy blue/green traffic shifting is introduced in the release
automation stage rather than being simulated here.

## Monitoring and notifications

The monitoring module consumes ALB, ECS, SQS, and log-group outputs directly.
It alarms on ALB 5xx rate and P95 latency, API/Worker CPU and memory, oldest SQS
message age, any DLQ message, model error rate, and Worker LLM P95 latency.
Missing traffic is non-breaching; missing ECS telemetry is breaching because it
can indicate a vanished service.

Set `alarm_notification_emails` in the environment tfvars to enable email.
Every recipient must confirm the SNS subscription before receiving alarm and
recovery notifications. Threshold variables are validated and may be tuned per
environment without editing the reusable module.

## Distributed tracing

Every API and Worker task runs
`public.ecr.aws/aws-observability/aws-otel-collector:v0.48.0` as an essential
sidecar with the AWS ECS default collector configuration. Application
containers depend on the collector start event and export only to the loopback
OTLP/gRPC endpoint. Collector logs share the service log group under the
`adot` stream prefix.

The API and Worker task roles may call only `xray:PutTraceSegments` and
`xray:PutTelemetryRecords` for tracing. The execution and GitHub roles receive
no X-Ray permission. Tune `otel_trace_sample_ratio` per environment; existing
parent decisions always win because the SDK uses parent-based sampling.

## Service autoscaling

The reusable `autoscaling` module registers both ECS services with Application
Auto Scaling. API CPU and memory policies use AWS predefined ECS target metrics.
The Worker follows the AWS queue-pressure pattern:

```text
ApproximateNumberOfMessagesVisible / RunningTaskCount
```

`RunningTaskCount` comes from the enabled ECS Container Insights. Each
environment supplies a non-zero availability floor and a hard task ceiling.
Scale-out waits 60 seconds; scale-in waits 300 seconds to avoid rapid churn.
The ECS service lifecycle ignores autoscaler-owned `desired_count` drift while
Terraform retains ownership of the capacity limits and scaling policies.

## Public API WAF boundary

The `waf` module associates a regional Web ACL directly with the public ALB.
Its custom rule blocks excessive traffic from a single source IP over a
five-minute window. AWS-managed IP reputation, known-bad-input, and common-rule
groups inspect the remaining traffic. Staging and production always instantiate
this boundary; development can disable it to avoid fixed WAF charges.

Sampled requests are disabled. WAF logging drops allowed requests, retains
blocked requests, and redacts the API key, authorization header, and query
string. The log group is retained per environment and uses the mandatory
`aws-waf-logs-` prefix. A blocked-request volume alarm publishes alarm and
recovery events to the platform's encrypted SNS topic.

## GitHub deployment variables

After applying the development stack, read the values required by the CD
workflow with:

```bash
terraform -chdir=terraform/environments/dev output -json deployment_github_variables
```

Create repository Actions variables with the returned names and values. They
contain no static AWS credentials. The workflow uses `AWS_DEPLOY_ROLE_ARN` only
to request a short-lived OIDC session, pushes images tagged with the tested
40-character commit SHA, and updates both ECS services. Terraform ignores only
the services' live `task_definition` revision so the CD workflow remains the
application-release owner. It also ignores live `desired_count`, which belongs
to Application Auto Scaling; capacity bounds remain Terraform-owned.

The staging root is deliberately stricter: it requires HTTPS, per-AZ NAT,
redundant API and Worker tasks, protected data/load-balancer resources, and the
existing account OIDC provider. Its deploy role trusts only the protected
GitHub `staging` environment and can read only the two configured dev source
repositories. Promotion verifies the builder's keyless signature and SPDX
attestation, copies the already-scanned ECR manifests by digest, and adds a
protected staging signature; it cannot substitute a rebuild.

Production adds a second ALB target group and an ECS CodeDeploy deployment
group using `CodeDeployDefault.ECSCanary10Percent5Minutes`. Five focused API
alarms stop traffic shifting and trigger automatic rollback; the old task set
is retained for a configurable bake window. The production GitHub role can
copy existing staging manifests and has the ECR layer APIs that keyless signing
requires, scoped to its two destination repositories. The workflow has no image
build step. Its CodeDeploy permissions remain scoped to the single production
deployment group, and ECS receives only the verified digest reference.

Production also creates a separate GitHub OIDC role for continuous evaluation.
It trusts only the exact `production-monitoring` environment subject and may
read the API verification secret, publish metrics only in
`CloudNativeLLMOps`, and conditionally create objects only under the artifact
bucket's `evaluations/` prefix. It has no ECR, ECS, CodeDeploy, or
`iam:PassRole` permissions.

The `cost_control` module creates the production account's monthly cost budget
and sends 80%-actual and 100%-forecast alerts to the same encrypted SNS topic.
The monitoring module grants only same-account, source-ARN-scoped AWS Budgets
publishing and adds a combined API/Worker hourly estimated LLM cost alarm.
Budget alerts are account-level so Bedrock invocation charges are not omitted
by resource-tag filtering; use a dedicated workload account or set the limit
to account for colocated workloads.

The production `audit` module creates a multi-Region management-event
CloudTrail with global-service coverage and log-file validation. A dedicated
KMS key encrypts both the private versioned S3 archive and the CloudWatch Logs
delivery. CloudTrail can write only the exact account prefix and trail ARN;
its CloudWatch role can create streams and publish events only in the audit log
group. Four metric filters reuse the encrypted operations topic for security
detections.

## Backup and recovery validation

Production composes the `backup` module around the exact artifact-bucket and
job-table ARNs. It keeps daily snapshots for 35 days and weekly snapshots for
365 days in a rotating customer-key-encrypted vault. A governance-mode vault
lock prevents recovery points from being shortened below the daily policy or
extended beyond the configured maximum while retaining an authorized
decommissioning path.

The backup execution role and restore-test role trust only AWS Backup and have
no ECR, ECS, CodeDeploy, or GitHub trust relationship. The monthly recovery
test selects the latest snapshot in the daily window and restores both S3 and
DynamoDB with a one-hour validation window. Treat the AWS Backup restore-test
history as the recovery drill record; investigate failures and confirm that
temporary S3 resources finish cleanup. Both retained recovery points and
restore drills incur service charges.

## Read-only incident diagnostics

The production `operations` module creates a separate GitHub OIDC identity for
the protected `production-operations` environment. It can describe only the
workload's ECS services, alarm prefix, two queues, management trail, recovery
vault/jobs, and CodeDeploy group. Unsupported resource-scoped list calls are
limited to read-only AWS Backup job metadata.

An explicit deny blocks secret retrieval, ECS/CodeDeploy mutation, remote
shells, queue mutation, backup starts/deletion, and `iam:PassRole`. Populate the
workflow environment from `operations_github_variables`; do not reuse the
deployment or evaluation role. The collector returns non-zero if any probe
fails but still writes partial diagnostic evidence for investigation.

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

For a new account, bootstrap the repositories before the full stack:

```bash
terraform -chdir=terraform/environments/dev apply \
  -target=module.api_ecr -target=module.worker_ecr
# authenticate Docker, then build and push API and Worker with the bootstrap tag
terraform -chdir=terraform/environments/dev apply
```

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
application-release owner; all other ECS configuration stays Terraform-owned.

The staging root is deliberately stricter: it requires HTTPS, per-AZ NAT,
redundant API and Worker tasks, protected data/load-balancer resources, and the
existing account OIDC provider. Its deploy role trusts only the protected
GitHub `staging` environment and can read only the two configured dev source
repositories. Promotion copies the already-scanned ECR manifests by digest;
it cannot substitute a rebuild.

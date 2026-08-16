# Staging

Production-like pre-release environment with isolated networking, per-AZ NAT,
two API and Worker tasks, deletion-protected DynamoDB and ALB resources, 90-day
logs, HTTPS-only application traffic, full alarms, and artifact-promotion-only
GitHub permissions.

Application Auto Scaling preserves the two-task availability floor while
allowing API capacity to reach six tasks and Worker capacity to reach ten. The
Worker targets two visible SQS inference jobs per running task.

The public ALB is unconditionally associated with AWS WAF. Per-IP throttling
and three AWS-managed threat rule groups block abusive traffic; redacted logs
retain blocked requests for 90 days.

Copy the examples, replace account-specific values, then initialize and apply:

```bash
cp terraform/environments/staging/terraform.tfvars.example terraform/environments/staging/terraform.tfvars
cp terraform/environments/staging/backend.s3.tfbackend.example terraform/environments/staging/backend.s3.tfbackend
terraform -chdir=terraform/environments/staging init -backend-config=backend.s3.tfbackend
terraform -chdir=terraform/environments/staging plan
terraform -chdir=terraform/environments/staging apply
terraform -chdir=terraform/environments/staging output -json deployment_github_variables
```

Bootstrap is intentionally two-phase because ECS may only reference an image
that already exists and a populated secret. First apply `module.api_ecr`,
`module.worker_ecr`, and `module.secrets`; populate the returned
`api_auth_secret_name` with a random 32-128 character URL-safe value; then copy
one already-scanned dev SHA into those repositories with ECR `batch-get-image`
and `put-image`, set both image-tag variables to that SHA, then perform the full
apply. Later releases use the protected workflow and need no manual copying.

Add the output values to the protected GitHub `staging` environment. Also add
`DEV_API_ECR_REPOSITORY` and `DEV_WORKER_ECR_REPOSITORY` there. The environment
OIDC subject, not a branch subject, is the only principal trusted to promote.
Configure required reviewers and a deployment-branch rule allowing only
`master`; the workflow independently rejects dispatches from any other ref.
`API_AUTH_SECRET_ID` is a non-secret identifier. The scoped OIDC role retrieves
and masks its value only while release verification is running.

The same protected environment drives `performance-staging.yml`. Supply the
full promoted commit SHA and deliberate duration, rate, and concurrency values.
The workflow refuses stale revisions by comparing the live API task-definition
image tag with that SHA, then applies the 1% error, 3-second P95, and 90%
throughput gates. Start with two requests per second and raise load only after
reviewing Bedrock quotas, autoscaling ceilings, and expected cost.

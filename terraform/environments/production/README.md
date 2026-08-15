# Production

Protected multi-AZ runtime with API CodeDeploy blue/green canaries, alarm-driven
automatic rollback, a rolling Worker circuit breaker, immutable artifact
promotion from staging, and a reviewer-gated GitHub environment.

Application Auto Scaling retains the three-task API and two-task Worker
baselines, with hard ceilings of 12 and 30 tasks. API capacity follows CPU and
memory; Worker capacity follows SQS backlog per running task.

Copy the tfvars and backend examples, replace account-specific values, and use
a two-phase bootstrap: first target both ECR modules and `module.secrets`,
populate `api_auth_secret_name` with a random 32-128 character URL-safe value,
copy one scanned staging SHA into the new repositories, set both image tags to
that SHA, then apply the full stack. The CodeDeploy service needs a healthy
initial blue task set.

```bash
terraform -chdir=terraform/environments/production init -backend-config=backend.s3.tfbackend
terraform -chdir=terraform/environments/production plan
terraform -chdir=terraform/environments/production apply
terraform -chdir=terraform/environments/production output -json deployment_github_variables
```

Put the output values plus `STAGING_API_ECR_REPOSITORY` and
`STAGING_WORKER_ECR_REPOSITORY` in the protected GitHub `production`
environment. Require reviewers, prevent self-review, enforce deployment from
`master` only, and confirm every SNS email subscription before releasing.

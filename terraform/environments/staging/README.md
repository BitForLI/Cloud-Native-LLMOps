# Staging

Production-like pre-release environment with isolated networking, per-AZ NAT,
two API and Worker tasks, deletion-protected DynamoDB and ALB resources, 90-day
logs, HTTPS-only application traffic, full alarms, and artifact-promotion-only
GitHub permissions.

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
that already exists. First apply `module.api_ecr` and `module.worker_ecr`, copy
one already-scanned dev SHA into those repositories with ECR `batch-get-image`
and `put-image`, set both image-tag variables to that SHA, then perform the full
apply. Later releases use the protected workflow and need no manual copying.

Add the output values to the protected GitHub `staging` environment. Also add
`DEV_API_ECR_REPOSITORY` and `DEV_WORKER_ECR_REPOSITORY` there. The environment
OIDC subject, not a branch subject, is the only principal trusted to promote.
Configure required reviewers and a deployment-branch rule allowing only
`master`; the workflow independently rejects dispatches from any other ref.

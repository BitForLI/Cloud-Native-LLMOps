# Production

Protected multi-AZ runtime with API CodeDeploy blue/green canaries, alarm-driven
automatic rollback, a rolling Worker circuit breaker, immutable artifact
promotion from staging, and a reviewer-gated GitHub environment.

Application Auto Scaling retains the three-task API and two-task Worker
baselines, with hard ceilings of 12 and 30 tasks. API capacity follows CPU and
memory; Worker capacity follows SQS backlog per running task.

The public ALB is unconditionally protected by AWS WAF with a 5,000-request
five-minute per-IP ceiling and AWS-managed reputation, known-input, and common
threat rules. Blocked traffic is redacted, retained for 365 days, and alarmed.

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
terraform -chdir=terraform/environments/production output -json operations_github_variables
terraform -chdir=terraform/environments/production output -json drift_github_variables
```

Create a `production-drift` GitHub environment restricted to `master`, copy its
five output variables, and add `PRODUCTION_TFVARS_JSON` as an environment secret
containing the complete JSON object used for production inputs. The daily
workflow reads the exact remote state with locking disabled, retains only a
value-free report, publishes `InfrastructureDriftDetected`, and fails on drift
or audit errors. Do not configure required reviewers on this environment because
scheduled audits must run unattended; its OIDC subject remains separate from
deployment and incident operations.

Set `monthly_budget_limit_usd` and
`alarm_llm_hourly_cost_threshold_usd` to deliberate operating limits before
apply. The first covers account billing spend; the second is the faster
application-estimated Bedrock signal. Confirm the SNS email subscription or
neither operational nor budget notifications will reach the recipient.

The production apply also creates a seven-year CloudTrail archive. Treat the
`audit_archive_bucket`, `audit_trail_name`, and `security_alarm_names`
values in `production_safety_profile` as operational inventory. The archive
bucket uses `force_destroy = false`; remove retained evidence explicitly only
through an approved decommissioning process.

AWS Backup adds an independently encrypted, governance-locked recovery vault.
Daily snapshots are retained for at least 35 days and weekly snapshots for at
least 365 days. The selection contains only the production artifact bucket and
job table; their existing S3 versioning and DynamoDB point-in-time recovery
remain the first line of defense for short-range recovery.

The monthly restore-testing plan restores the latest eligible S3 and DynamoDB
snapshots through a dedicated restore role, with a one-hour validation window.
Inspect its results in AWS Backup restore testing and alert operational owners
on any failed validation. AWS Backup removes test resources after the window,
although S3 cleanup can remain in progress; verify cleanup and charges after
every drill. Neither backup service role is a deployment role.

Before changing retention, confirm `daily <= weekly <= vault maximum`. The
vault uses governance mode by design; switching to irreversible compliance
mode requires a separately reviewed retention and decommissioning decision.

Put the output values plus `STAGING_API_ECR_REPOSITORY` and
`STAGING_WORKER_ECR_REPOSITORY` in the protected GitHub `production`
environment. Require reviewers, prevent self-review, enforce deployment from
`master` only, and confirm every SNS email subscription before releasing.

Create a separate `production-operations` GitHub environment restricted to
`master` and trusted incident responders. Populate it only from
`operations_github_variables`. Its dedicated OIDC role is read-only and cannot
retrieve the API secret or mutate production. Run `Diagnose Production
Incident` with a non-secret incident ID, retain its artifact in the incident
record, and follow the procedures in `docs/runbooks/` for any approved recovery
action.

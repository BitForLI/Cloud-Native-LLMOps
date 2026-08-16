# Cloud-Native LLMOps Platform on AWS

Production-oriented LLM service platform: automated quality gates, container delivery, ECS deployment, observability, and a safe rollback path.

## Architecture

```text
GitHub PR -> lint / pytest / LLM evaluation / security scan
   -> main -> Docker build -> Amazon ECR -> AWS WAF / ALB -> ECS Fargate -> Bedrock
                                             |       |       |
                                CloudWatch/X-Ray/CloudTrail  S3  DynamoDB
                                             |
                              Application Auto Scaling <- SQS backlog
```

## Repository layout

- `services/api`: FastAPI inference service and health endpoints.
- `services/worker`: reusable asynchronous job domain and worker runtime.
- `evals`: deterministic, CI-friendly LLM evaluation dataset and quality gate.
- `terraform`: reusable AWS modules and per-environment stacks.
- `.github/workflows`: pull-request validation and build/deploy workflow.

## Local start

```bash
cp .env.example .env
docker compose up --build
# http://localhost:8000/health
```

The production images run as UID/GID `10001`, use read-only root filesystems,
drop Linux capabilities, and expose container health checks. The API image is
multi-stage and contains runtime dependencies only; development and test
packages live in `services/api/requirements-dev.txt`.

The API uses a deterministic local provider when `LLM_PROVIDER=local`. Set it
to `bedrock` after completing the Bedrock runtime integration. Keeping the
provider behind an interface makes tests and CI reproducible without AWS
credentials.

### Amazon Bedrock mode

Set `LLM_PROVIDER=bedrock` and choose an Anthropic Claude model in
`BEDROCK_MODEL_ID`. The runtime uses the standard boto3 credential chain; on
ECS, credentials should come from the task role. The caller needs
`bedrock:InvokeModel` permission and access to the selected model. Never place
AWS access keys in `.env` or commit them to the repository.

### Request observability

Every HTTP response includes `X-Request-ID`. Application logs are JSON and
record the request ID, method, route template, status, latency, selected model,
error type, and active OpenTelemetry trace/span IDs. Prompt and response
content are deliberately excluded.

`GET /metrics` exposes the process-local request/error rate, LLM P50/P95
latency, model error rate, token totals, and accumulated estimated cost. Cost
rates are configuration values because Bedrock pricing varies by model and
region. API and Worker inference attempts also emit prompt-free CloudWatch
Embedded Metric Format events for request count, model errors, latency, token
usage, and estimated cost.

The Terraform monitoring module builds a six-panel CloudWatch operations
dashboard spanning ALB traffic/latency, ECS CPU/memory/task capacity, SQS
backlog/DLQ, LLM signals, and recent errors. Production-style 3-of-5 alarms cover HTTP and model
error rates, P95 latency, resource saturation, queue age, and dead letters.
Alarm and recovery notifications use an SNS topic protected by a rotating
customer-managed KMS key; optional email recipients must confirm their SNS
subscriptions before alerts are delivered.

### Cost guardrails

Production combines two cost signals. CloudWatch sums prompt-free
`EstimatedCostUSD` metrics from both API and Worker every hour and alerts when
the configurable fast guardrail is exceeded. AWS Budgets provides the slower
billing-level control: by default it warns at 80% actual spend and when the
monthly account forecast reaches 100% of the configured USD budget. Both use
the existing encrypted SNS topic and confirmed recipients.

The default production values are `$10/hour` for application-estimated LLM
cost and `$100/month` for the AWS account budget. Override them for the model,
traffic, and account boundary you actually operate. The budget deliberately
alerts instead of shutting infrastructure down: an automatic cost kill switch
could interrupt production or make durable data unavailable. AWS billing data
is delayed, so the hourly application metric is the earlier signal.

### Security audit trail

Production enables one continuously logging, multi-Region CloudTrail including
global management events such as IAM changes. Audit files go to a dedicated
private, versioned S3 bucket encrypted by a rotating customer-managed KMS key.
CloudTrail log-file validation signs digest chains so operators can detect
modification or deletion; archives default to seven-year retention.

The trail also streams to an encrypted CloudWatch log group. Metric filters
raise SNS alarms for unauthorized API calls, root-account use, IAM writes, and
changes that stop, delete, or reconfigure the trail. Broad Bedrock and S3 data
events are intentionally excluded: this audit layer records the control plane
without copying prompts or other application payloads into security logs.

### Backup and recovery drills

Production combines S3 versioning and DynamoDB PITR with scheduled AWS Backup
recovery points. A dedicated customer-key-encrypted vault retains daily
snapshots for 35 days and weekly snapshots for one year under governance
retention lock. Only the artifact bucket and job table are selected, and AWS
Backup roles are isolated from deployment identities.

A monthly restore-testing plan restores the latest eligible S3 and DynamoDB
snapshots through a separate restore role. Its one-hour validation window is a
repeatable recovery-drill entry point; operations must review failed tests and
verify completion of temporary-resource cleanup.

### Incident diagnostics and runbooks

`diagnose-production.yml` collects a prompt-free control-plane snapshot for a
bounded incident window: ECS rollout/capacity, workload alarms, inference and
dead-letter queues, CloudTrail delivery, backup/restore jobs, and the
CodeDeploy group. It runs only through the exact protected
`production-operations` OIDC subject and retains the JSON artifact for 30 days.

The operations role is intentionally unable to read Secrets Manager, execute a
container shell, update ECS, start/stop CodeDeploy, mutate queues, pass roles,
or start/delete backup operations. Diagnosis and recovery authority remain
separate. Operational procedures for deployment regression, queue backlog,
Bedrock degradation, and restore-test failure live in `docs/runbooks/`.

OpenTelemetry instruments FastAPI and botocore calls. API and Worker task
definitions each include an essential, version-pinned AWS Distro for
OpenTelemetry Collector sidecar. Applications send OTLP/gRPC only to
`127.0.0.1:4317`; the collector converts and exports spans to AWS X-Ray using
the task role. Health/readiness probes are excluded, parent sampling decisions
are preserved, staging samples all release traffic, and production defaults to
10% root sampling.

Asynchronous jobs carry only the bounded `X-Amzn-Trace-Id` context in the
versioned SQS envelope. The Worker continues the originating API trace through
DynamoDB, SQS, and Bedrock operations. Custom LLM and job spans exclude prompts,
responses, credentials, and exception messages from attributes and events.

### Automatic capacity management

Application Auto Scaling keeps every environment inside explicit availability
floors and cost ceilings. The API has independent target-tracking policies for
average ECS CPU (60%) and memory (70%): either signal can add capacity, while
scale-in waits until both policies agree. A 60-second scale-out cooldown reacts
quickly to demand; a 300-second scale-in cooldown reduces task churn.

Worker capacity follows inference demand rather than CPU. The policy divides
SQS `ApproximateNumberOfMessagesVisible` by Container Insights
`RunningTaskCount` and targets two queued jobs per running Worker. Development
is capped at 3 API/5 Worker tasks, staging at 6/10, and production at 12/30.
ECS desired counts are availability baselines and Terraform ignores subsequent
changes owned by the autoscaler.

### Public API edge security

Staging and production ALBs are always associated with a regional AWS WAF Web
ACL. It blocks per-IP request floods and evaluates AWS-managed IP reputation,
known-bad-input, and common-threat rule groups before traffic reaches FastAPI.
Development leaves WAF disabled by default to avoid its fixed cost, but uses the
same module when `enable_waf=true`.

WAF request sampling is disabled. Logging keeps blocked requests only and
redacts `Authorization`, `X-API-Key`, and query strings before sending records
to the required `aws-waf-logs-*` CloudWatch group. Abnormal blocking volume
raises a CloudWatch alarm through the existing encrypted SNS notification path.

### API authentication and secret handling

`/v1/generate`, `/v1/jobs*`, and `/metrics` require `X-API-Key` whenever
`API_AUTH_TOKEN` is configured. `/health` and `/ready` intentionally remain
unauthenticated for ALB/ECS probes. Deployed `dev`, `staging`, and `production`
processes fail configuration validation unless the token contains 32-128
URL-safe characters.

Terraform creates an empty Secrets Manager secret encrypted by an
environment-specific customer-managed KMS key with automatic key rotation. It
never manages a secret version, so plaintext does not enter Terraform state.
ECS injects the current value at task startup. Staging and production release
roles may read only that secret for authenticated integration/evaluation calls;
GitHub masks the value immediately and does not store it as an Actions secret.

### Asynchronous inference

Submit work with `POST /v1/jobs` and poll `GET /v1/jobs/{job_id}`. Jobs move
through `pending -> running -> succeeded|failed`; completed responses include
model, token, cost, and output metadata. Prompts are transient queue payloads,
and public failures contain a stable error code rather than provider exception
details.

`JOB_BACKEND=memory` uses a bounded in-process queue and repository for
deterministic local development. ECS sets `JOB_BACKEND=aws`: the API creates a
TTL-backed DynamoDB record and sends a versioned SQS message; the independent
Worker long-polls SQS, invokes Bedrock, conditionally updates DynamoDB, and only
deletes a message after the result is durable. Standard-queue duplicate
deliveries are idempotent, retryable failures remain unacknowledged, and final
failures are retained for the configured DLQ redrive policy.

The prompt exists only in the transient SQS payload. It is not stored in
DynamoDB or application logs. `GET /ready` checks DynamoDB and SQS in AWS mode,
while `/health` remains a shallow process health check for the ALB.

Tune local resource bounds with `JOB_MAX_WORKERS`, `JOB_MAX_PENDING`,
`JOB_MAX_STORED`, and `JOB_POLL_INTERVAL_SECONDS`. `JOB_MAX_STORED` must be at
least `JOB_MAX_PENDING`.

### Terraform foundation

The development infrastructure composes reusable networking and ECR modules.
It creates multi-AZ public/private subnet tiers, configurable NAT egress, an S3
gateway endpoint, and separate encrypted immutable repositories for API and
Worker images. Terraform validation runs in CI; no AWS credentials are required
for that static validation job. See `terraform/README.md` for state and cost
guidance.

The data layer adds a private versioned S3 artifact bucket, an encrypted
on-demand DynamoDB job table with TTL/PITR, and an encrypted long-poll SQS queue
with bounded retries and a 14-day dead-letter queue. ECS explicitly selects the
durable application backend for API and Worker tasks.

IAM separates API producer, Worker consumer, ECS image/log delivery, and GitHub
deployment permissions. GitHub uses short-lived OIDC credentials restricted to
this repository's immutable identity and `master`; no static AWS access keys are
required. API and Worker task roles grant their local collectors only the two
X-Ray write actions required to publish segments and telemetry records.

ECS Fargate runs the API and Worker in private subnets without public IPs. The
WAF-protected public ALB reaches only API port `8000`; task definitions enforce non-root users,
read-only roots, writable Fargate-ephemeral `/tmp` mounts, container health checks, and
separate runtime roles. Failed rolling deployments trigger the ECS deployment
circuit breaker and automatic rollback.

CloudWatch monitoring composes resource outputs directly: ALB/TG suffixes, ECS
service names, SQS queue names, and log groups become dashboard and alarm
dimensions. Alert thresholds and recipients remain validated per-environment
Terraform inputs.

## Delivery model

1. PR: format/lint, unit tests, evaluation quality gate, dependency security scan.
2. `main`: build and tag an immutable image, push to ECR, deploy to development.
3. Promotion: staging integration, evaluation, and performance gates precede production.
4. Production: ECS blue/green deployment validates health and alarms; a failed deployment keeps or restores the prior task set.

### Development continuous delivery

After the complete `CI` workflow succeeds for a `master` push,
`deploy-dev.yml` checks out that exact tested SHA and assumes the scoped AWS
deployment role through GitHub OIDC. It builds and locally smoke-tests both
hardened images, pushes immutable SHA tags, blocks HIGH/CRITICAL ECR scan
findings, registers task definitions, and rolls API and Worker together.

The workflow waits for ECS stability, verifies that the circuit breaker did not
silently restore an older revision, then checks public `/health` and dependency
`/ready`. Any deployment or smoke-test failure restores both previous task
definitions. Concurrent deployments are serialized. If `AWS_DEPLOY_ROLE_ARN`
is not configured, the deployment job is safely skipped while CI still runs.

Configure the repository Actions variables listed by the Terraform
`deployment_github_variables` output. AWS credentials are never stored in
GitHub; only the non-secret role ARN, account/region, resource names, and API
origin are required.

### Staging artifact promotion

The protected `staging` GitHub environment accepts a manually selected full
commit SHA only after confirming that SHA has a successful `master` CI run.
It also requires a successful, non-skipped development deploy job for the same
SHA, so staging cannot bypass the dev integration stage.
`promote-staging.yml` does not rebuild containers: it copies the dev image
manifests into immutable staging repositories and proves both destination
digests equal their scanned dev sources.

The promotion then rolls API and Worker together, verifies ECS did not silently
roll back, exercises health/readiness and synchronous Bedrock inference, and
submits and polls a durable SQS/DynamoDB Worker job. Any failed integration
gate restores both prior staging task definitions. Terraform provisions
staging with HTTPS, per-AZ NAT, redundant tasks, deletion protection, longer
retention, alarms, and an OIDC role scoped to the `staging` environment and the
two dev source repositories.

The GitHub environment must require reviewers and restrict deployments to
`master`; the workflow also rejects dispatches from other refs.

### Staging performance gate

`performance-staging.yml` provides a serialized, reviewer-protected manual
capacity gate for an exact revision already promoted to staging. It verifies
the successful promotion record, confirms that ECS still runs that SHA, checks
health/readiness, then retrieves the API token through short-lived AWS OIDC
credentials. No static credential or token is stored in GitHub.

The bounded load generator exercises authenticated `/v1/generate` traffic at
the requested fixed rate and concurrency. By default it requires at most 1%
errors, P95 client latency at most 3 seconds, and at least 90% of target
throughput. Its retained JSON artifact contains aggregate measurements only—no
prompt, response, or API key. Duration, rate, and concurrency are validated to
prevent accidental unbounded tests; Bedrock requests still incur AWS charges.
Production release refuses that SHA until both its staging promotion and its
staging performance job have completed successfully.

### Production canary release

`release-production.yml` requires the exact SHA to have a successful,
non-skipped staging promotion and performance gate, then pauses at the
protected `production` GitHub environment for reviewer approval. It promotes
the same scanned ECR manifests—production IAM cannot upload new image
layers—then updates the
headless Worker with its ECS circuit breaker and releases the API through
CodeDeploy blue/green.

Before touching ECS or ECR, the workflow also reads seven days of production
ALB telemetry through narrowly scoped OIDC credentials. The fail-closed SLO
gate requires at least 100 requests, 99.9% availability budget remaining, and
99% of populated five-minute periods to keep P95 target latency at or below
three seconds. Target and load-balancer 5xx both consume the availability
budget. Its prompt-free JSON decision record is retained for 90 days; exhausted
budgets or insufficient observations freeze the release and route operators to
the error-budget runbook.

### Signed software supply chain

Development delivery generates SPDX JSON SBOMs for the API and Worker images
with pinned Syft, retains them for 90 days, and attaches them to the immutable
image digests as keyless Cosign attestations. The same GitHub OIDC identity signs
each digest with the exact commit SHA as a required annotation; there are no
long-lived signing keys.

Staging refuses an image unless both its builder signature and SBOM attestation
verify against the exact `deploy-dev.yml` identity. It then signs the unchanged
digest with the protected staging identity. Production accepts only that exact
staging identity, signs the production copy, verifies it again, and registers
ECS task definitions using `repository@sha256:...` references. A tag collision,
missing SBOM, wrong workflow identity, wrong commit annotation, digest change,
or transparency verification failure stops delivery before ECS is modified.
Operational response is documented in the
[`supply-chain-verification-failure`](docs/runbooks/supply-chain-verification-failure.md)
runbook; signing-service outages freeze new releases without affecting the
already digest-pinned tasks.

### Infrastructure drift and policy evidence

`drift-production.yml` runs every day and on demand in the protected
`production-drift` environment. A dedicated OIDC role can read exactly one
Terraform state object plus control-plane configuration; it cannot lock or write
state, mutate infrastructure, read application secrets, inspect DynamoDB items,
or retrieve Parameter Store values; its only write is the constrained drift
metric. The workflow uses `terraform plan -detailed-exitcode`
with locking disabled and treats a non-empty plan or audit error as failure.

Policy-as-code classifies deletion/replacement, identity, network, secret, and
data-protection changes. Raw state, raw plans, and before/after values remain
ephemeral; the retained 90-day JSON contains only addresses, action types, and
classifications. A binary CloudWatch metric drives the encrypted production SNS
alarm, while five missing six-hour heartbeat periods detect a missed audit after
approximately 30 hours without daily boundary false positives. Recovery follows the
[`infrastructure-drift`](docs/runbooks/infrastructure-drift.md) runbook and never
auto-applies an unreviewed plan.

The ALB runs two target groups. CodeDeploy shifts 10% of production traffic to
green for five minutes, watches focused API/LLM/compute CloudWatch alarms, then
shifts the remaining 90%. An alarm or deployment failure automatically returns
traffic to blue. Synthetic health and Bedrock requests exercise the canary
throughout the shift so low organic traffic cannot leave its alarms idle.
Post-release health, real Bedrock evaluation, cost/latency
gates, and durable Worker tests run before completion; a later verification
failure starts a reverse CodeDeploy deployment and restores the prior Worker.

### Continuous production evaluation

`monitor-production-eval.yml` runs the remote evaluation dataset every day at
03:17 UTC and can also be dispatched manually from `master`. It publishes
accuracy, P95 latency, estimated cost, and aggregate pass/fail metrics to the
`CloudNativeLLMOps` namespace. The production dashboard includes those trends;
the encrypted SNS alarm path reports a failed gate immediately and a missing
daily evaluation after approximately 30 hours.

Every run stores a prompt-free JSON report under
`s3://<artifact-bucket>/evaluations/production/YYYY/MM/DD/`. The key contains
the GitHub run identity and full revision, includes the dataset SHA-256, and is
written with `If-None-Match: *`, a content checksum, and encryption so reruns
cannot silently replace evidence.

Create a `production-monitoring` GitHub environment restricted to `master`.
Do not add a required-reviewer wait to this environment because scheduled
monitoring must run unattended; keep human approval on the separate
`production` release environment. Copy `AWS_ACCOUNT_ID`, `AWS_REGION`,
`AWS_EVALUATION_ROLE_ARN`, `API_URL`, `API_AUTH_SECRET_ID`, and
`ARTIFACT_BUCKET` from Terraform's `deployment_github_variables` output into
the monitoring environment. Its dedicated OIDC role cannot push images,
register task definitions, update ECS, or invoke CodeDeploy.

## Quality gate defaults

- Exact-response evaluation score: `>= 0.90`
- Tool success rate: `>= 0.95` when tool cases are present
- P95 latency: `<= 3000 ms`
- Total estimated evaluation cost: `<= $0.10`

Run the same gate locally with:

```bash
python -m evals.run_eval
```

Thresholds can be overridden with `EVAL_ACCURACY_THRESHOLD`,
`EVAL_TOOL_SUCCESS_THRESHOLD`, `EVAL_P95_LATENCY_THRESHOLD_MS`, and
`EVAL_MAX_ESTIMATED_COST_USD`. A failed gate exits non-zero and blocks CI.

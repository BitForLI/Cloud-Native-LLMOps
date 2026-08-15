# Cloud-Native LLMOps Platform on AWS

Production-oriented LLM service platform: automated quality gates, container delivery, ECS deployment, observability, and a safe rollback path.

## Architecture

```text
GitHub PR -> lint / pytest / LLM evaluation / security scan
   -> main -> Docker build -> Amazon ECR -> ECS Fargate -> Bedrock
                                             |       |       |
                                          CloudWatch  S3  DynamoDB
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
and error type. Prompt and response content are deliberately excluded.

`GET /metrics` exposes the process-local request/error rate, LLM P50/P95
latency, model error rate, token totals, and accumulated estimated cost. Cost
rates are configuration values because Bedrock pricing varies by model and
region. API and Worker inference attempts also emit prompt-free CloudWatch
Embedded Metric Format events for request count, model errors, latency, token
usage, and estimated cost.

The Terraform monitoring module builds a six-panel CloudWatch operations
dashboard spanning ALB traffic/latency, ECS CPU/memory, SQS backlog/DLQ, LLM
signals, and recent errors. Production-style 3-of-5 alarms cover HTTP and model
error rates, P95 latency, resource saturation, queue age, and dead letters.
Alarm and recovery notifications use an SNS topic protected by a rotating
customer-managed KMS key; optional email recipients must confirm their SNS
subscriptions before alerts are delivered.

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
required.

ECS Fargate runs the API and Worker in private subnets without public IPs. The
public ALB reaches only API port `8000`; task definitions enforce non-root users,
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
3. Promotion: staging integration/eval checks precede production.
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

### Production canary release

`release-production.yml` requires the exact SHA to have a successful,
non-skipped staging promotion and then pauses at the protected `production`
GitHub environment for reviewer approval. It promotes the same scanned ECR
manifests—production IAM cannot upload new image layers—then updates the
headless Worker with its ECS circuit breaker and releases the API through
CodeDeploy blue/green.

The ALB runs two target groups. CodeDeploy shifts 10% of production traffic to
green for five minutes, watches focused API/LLM/compute CloudWatch alarms, then
shifts the remaining 90%. An alarm or deployment failure automatically returns
traffic to blue. Synthetic health and Bedrock requests exercise the canary
throughout the shift so low organic traffic cannot leave its alarms idle.
Post-release health, real Bedrock evaluation, cost/latency
gates, and durable Worker tests run before completion; a later verification
failure starts a reverse CodeDeploy deployment and restores the prior Worker.

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

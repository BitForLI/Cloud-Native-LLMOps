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
- `services/worker`: asynchronous job worker placeholder.
- `evals`: deterministic, CI-friendly LLM evaluation dataset and quality gate.
- `terraform`: reusable AWS modules and per-environment stacks.
- `.github/workflows`: pull-request validation and build/deploy workflow.

## Local start

```bash
cp .env.example .env
docker compose up --build
# http://localhost:8000/health
```

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

## Delivery model

1. PR: format/lint, unit tests, evaluation quality gate, dependency security scan.
2. `main`: build and tag an immutable image, push to ECR, deploy to development.
3. Promotion: staging integration/eval checks precede production.
4. Production: ECS blue/green deployment validates health and alarms; a failed deployment keeps or restores the prior task set.

## Quality gate defaults

- Exact-response evaluation score: `>= 0.90`
- Tool success rate: `>= 0.95` (to be added with tool calling)
- P95 latency and cost thresholds: enforced once telemetry is wired into the evaluator

# Error budget exhaustion

Use this runbook when the protected production release reports that the rolling
availability or latency budget is exhausted, observations are missing, or the
minimum traffic requirement is not met. The gate is intentionally fail-closed:
do not bypass it by lowering an objective during an incident.

## Triage

1. Download `production-error-budget-<SHA>` and record its workflow URL.
2. Confirm the report window, request count, target 5xx, ALB 5xx, populated P95
   periods, and the individual failed gates.
3. Run the read-only production diagnostics workflow with an incident ID.
4. Correlate the first unhealthy period with ALB, ECS, Bedrock, queue, and
   CodeDeploy telemetry; do not inspect prompts or model responses.

## Decision

- If traffic is below the required sample, keep the release frozen and restore
  representative monitored traffic. Never manufacture successful samples.
- If availability is exhausted, stop releases until 5xx generation is fixed and
  enough healthy traffic ages through the rolling window.
- If latency is exhausted, isolate ALB target time from Bedrock and Worker queue
  time, then correct the responsible layer.
- If the regression is caused by the current version, execute the protected
  rollback path; the diagnostics role cannot mutate production.

## Recovery validation

Confirm health/readiness, authenticated inference, durable Worker completion,
normal CloudWatch alarms, and a passing continuous evaluation. Re-run the
release only after the unchanged SLO policy produces a passing report. Retain
both failed and recovered reports with the incident timeline.

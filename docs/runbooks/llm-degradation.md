# Bedrock or model-quality degradation

## Trigger

Model-error rate, LLM P95 latency, continuous evaluation accuracy, missing
evaluation, or estimated-cost alarms breach their production threshold.

## Diagnosis

Use `production-diagnostics.json` to exclude ECS, queue, and deployment faults.
Compare the active immutable revision, Bedrock region/model status, quota usage,
evaluation dataset hash, latency, token, cost, and accuracy trends. Never copy
raw prompts or responses into the incident channel.

## Containment

Freeze prompt/model/code releases. Rate-limit optional callers if throttling is
driving failures. Keep health endpoints available; do not disable quality or
cost alarms to make the incident appear resolved.

## Recovery

Rollback the last application/prompt revision through the production canary
workflow. A model change requires the normal evaluation, staging promotion,
performance gate, and reviewer approval—no console substitution.

## Validation

Run the remote evaluation gate, authenticated inference, and durable Worker
test. Require accuracy, tool success, P95, error, and cost thresholds to pass
and alarms to recover before unfreezing releases.

## Evidence

Retain revision/model IDs, aggregate metrics, evaluation report hash, alarm
timeline, diagnostic artifact, and approval. Exclude prompts, responses, tokens,
and customer identifiers.

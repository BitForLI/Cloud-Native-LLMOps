# Queue backlog or dead-letter growth

## Trigger

Oldest-message-age, visible-backlog, missing Worker, or dead-letter queue alarms
enter ALARM, or durable jobs stop reaching a terminal state.

## Diagnosis

Inspect ECS Worker desired/running/pending counts and inference/dead-letter
attributes in `production-diagnostics.json`. Correlate with Worker model-error,
latency, CPU, memory, and autoscaling alarms. Determine whether work is slow,
retrying, poison, or blocked by Bedrock quota.

## Containment

Pause upstream bulk submitters when backlog age threatens the job TTL. Do not
purge either queue. Do not redrive dead-letter messages until the failure is
fixed and idempotency for the affected message version is confirmed.

## Recovery

Remove the dependency or code failure, then allow bounded Worker autoscaling to
drain the source queue. Redrive a small reviewed DLQ sample before the remainder;
stop if model errors or duplicate side effects appear.

## Validation

Verify queue age and depth trend downward, Worker capacity stays within bounds,
sampled jobs complete once, and the dead-letter alarm returns to OK.

## Evidence

Keep queue counts before/after, affected message version, redrive approval and
batch size, Worker revision, Bedrock quota evidence, and diagnostic artifact.

# Deployment regression

## Trigger

API/Worker errors, latency, or health alarms begin during or immediately after
a production release, or CodeDeploy reports a failed/paused deployment.

## Diagnosis

Run the diagnostic workflow and compare `lastAttemptedDeployment`,
`lastSuccessfulDeployment`, ECS task definitions, rollout state, and alarm
timestamps in `production-diagnostics.json`. Confirm the failing SHA and whether
only API, only Worker, or both are affected.

## Containment

Stop new releases. If traffic shifting is active, use the protected production
release path to stop it with automatic rollback enabled. Do not directly call
`ecs update-service` for the CodeDeploy-controlled API.

## Recovery

Allow CodeDeploy to return API traffic to the prior blue task set. Restore the
Worker's previous task definition through the release script's tested rollback
path. If rollback itself fails, escalate to the platform owner and AWS support;
do not improvise task definitions during the incident.

## Validation

Check both target groups, ECS desired/running counts, `/health`, `/ready`, one
authenticated Bedrock inference, one durable job, and all deployment alarms.

## Evidence

Record both task-definition ARNs, deployment IDs, alarm transitions, rollback
approval, diagnostic artifact, and the exact revision ultimately serving.

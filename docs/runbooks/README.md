# Production incident response

These runbooks separate evidence collection from state-changing recovery. Start
the protected `Diagnose Production Incident` workflow with a non-secret incident
ID. It assumes the dedicated `production-operations` role and writes
`production-diagnostics.json`; that role is explicitly denied secret reads,
remote shell access, deployments, queue mutation, and backup/restore changes.

## Trigger

- A production SNS alarm, failed release verification, missing evaluation, or
  customer-impact report opens an incident.
- Use a stable identifier such as `INC-2026-001`; never put customer data,
  prompts, credentials, or tokens in the identifier.

## Diagnosis

1. Record detection time, incident commander, affected endpoint, and severity.
2. Run diagnostics with a lookback covering the first observed symptom.
3. Inspect failed probes first, then ALARM states, ECS desired/running gaps,
   queue depth, CloudTrail delivery, CodeDeploy state, and recovery jobs.
4. Select the specialized runbook matching the dominant failure mode.

## Containment

- Freeze production releases until an incident commander declares the release
  path safe.
- Use the protected deployment workflow for rollback; never broaden the
  diagnostics role or use it to mutate production.
- Do not purge queues, delete recovery points, or rotate secrets without a
  separately approved procedure and impact assessment.

## Recovery

- Restore the smallest failed layer: release, provider configuration, Worker
  capacity, or data resource.
- Prefer automated CodeDeploy/ECS rollback paths already tested by the platform.
- Assign an operator and reviewer for every production mutation.

## Validation

- Confirm `/health`, `/ready`, authenticated inference, durable Worker jobs,
  CloudWatch alarm recovery, and continuous evaluation.
- Observe one full alarm evaluation period after apparent recovery.

## Evidence

Retain the diagnostic artifact, relevant workflow run URLs, approved commands,
change identifiers, timestamps, and validation results. The artifact contains
control-plane metadata only and is retained for 30 days; move the incident
timeline to the organization's durable incident system before expiry.

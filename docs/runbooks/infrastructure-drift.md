# Production infrastructure drift

Use this runbook when `Audit Production Drift` fails or the
`InfrastructureDriftDetected` alarm enters `ALARM`. The audit is read-only: it
does not acquire the state lock, apply changes, or repair drift automatically.

## Triage

1. Record the workflow run, audited Git revision, detection time, and incident
   identifier. Download the 90-day `production-drift-<run-id>` artifact.
2. Distinguish `drift` from `error`. Drift means Terraform produced a non-empty
   plan; error means state or control-plane inspection did not complete.
3. Review changed resource addresses, actions, and policy classifications. The
   report intentionally excludes before/after values and raw state.
4. Prioritize `destructive_change`, `resource_replacement`, identity, network,
   secret, and data-protection findings. Correlate them with CloudTrail and the
   approved change log using the read-only diagnostics workflow.

## Containment

- Freeze infrastructure and application releases when identity, network,
  encryption, backup, state, or deletion-protection controls changed.
- Do not run `terraform apply` simply to make the alarm green. First determine
  whether Terraform code is stale or an unauthorized out-of-band change exists.
- Do not grant the drift role mutation, secret-value, data-item, state-write, or
  state-lock permissions.

## Recovery

- For unauthorized console/API drift, obtain approval and restore the declared
  configuration through the normal Terraform delivery process.
- For an intentional emergency change, encode and review the desired state in
  Terraform before reconciling it.
- For audit errors, restore backend/control-plane read access without broadening
  the role beyond the exact state object and managed resources.

## Validation and evidence

Re-run the protected workflow and require a `clean` report with zero changed
resources. Confirm the CloudWatch metric returns to zero and the alarm recovers.
Retain both reports, CloudTrail evidence, approvals, corrective commit, plan/apply
run, and post-change validation in the incident timeline.

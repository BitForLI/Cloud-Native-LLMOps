# Backup or restore-test failure

## Trigger

A scheduled backup job fails, the recovery vault becomes unhealthy, or monthly
AWS Backup restore testing reports a failed validation or incomplete cleanup.

## Diagnosis

Inspect the vault lock, recovery-point count, recent backup and restore jobs in
`production-diagnostics.json`. Confirm S3 versioning, DynamoDB PITR, AWS Backup
service-role health, KMS key availability, and whether failure affects one or
both protected resources.

## Containment

Do not delete recovery points, weaken retention, disable vault lock, or retry by
overwriting production. Preserve native S3 versions and DynamoDB PITR. Escalate
immediately if the 24-hour snapshot RPO is at risk.

## Recovery

Correct IAM/KMS/service issues through reviewed Terraform. Retry only into
temporary restore-test resources through the approved restore role. For a real
data incident, select a timestamp/recovery point with the data owner and restore
to isolated resources before any cutover.

## Validation

Validate object versions/checksums, DynamoDB item counts and application reads,
then record recovery point, observed RPO/RTO, and cleanup completion. Never use
test-resource existence alone as proof of recoverability.

## Evidence

Retain job IDs/status, vault configuration, selected recovery point, validation
results, diagnostic artifact, approvals, and temporary-resource cleanup time.

# Backup module

Creates a customer-KMS-encrypted AWS Backup vault in governance lock mode,
daily and weekly snapshot rules, and an explicit selection for one versioned
S3 bucket and one DynamoDB table. Separate service roles execute backups and
restores; neither role is reused by deployment automation.

When enabled, the monthly restore-testing plan selects the latest snapshot in
the daily retention window and temporarily restores both protected resource
types. AWS Backup owns cleanup of test resources after the one-hour validation
window. Restore tests and retained snapshots incur AWS charges.

The module deliberately omits `changeable_for_days`: vault lock remains in
governance mode, enforcing retention while preserving an authorized Terraform
decommissioning path. Compliance mode is irreversible after its grace period
and therefore requires a separate, explicitly approved operational decision.

output "vault_name" {
  description = "Governance-locked backup vault name."
  value       = aws_backup_vault.this.name
}

output "vault_arn" {
  description = "Governance-locked backup vault ARN."
  value       = aws_backup_vault.this.arn
}

output "kms_key_arn" {
  description = "Customer-managed key encrypting the backup vault."
  value       = aws_kms_key.backup.arn
}

output "plan_id" {
  description = "AWS Backup plan ID."
  value       = aws_backup_plan.this.id
}

output "plan_name" {
  description = "AWS Backup plan name."
  value       = aws_backup_plan.this.name
}

output "protected_resource_arns" {
  description = "Exact resources assigned to the backup plan."
  value       = toset(aws_backup_selection.data.resources)
}

output "restore_testing_plan_name" {
  description = "Monthly restore testing plan, or null when disabled."
  value       = try(aws_backup_restore_testing_plan.this[0].name, null)
}

output "restore_testing_plan_arn" {
  description = "Monthly restore testing plan ARN, or null when disabled."
  value       = try(aws_backup_restore_testing_plan.this[0].arn, null)
}

output "retention_days" {
  description = "Retention and vault-lock limits."
  value = {
    daily         = var.daily_retention_days
    weekly        = var.weekly_retention_days
    vault_minimum = var.daily_retention_days
    vault_maximum = var.vault_max_retention_days
  }
}

output "service_role_arns" {
  description = "Separate AWS Backup execution and restore-test roles."
  value = {
    backup  = aws_iam_role.backup.arn
    restore = aws_iam_role.restore.arn
  }
}

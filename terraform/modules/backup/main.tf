data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  vault_name                = "${var.name}-recovery"
  restore_testing_plan_name = "${replace(var.name, "-", "_")}_monthly_restore"
  common_tags               = merge(var.tags, { Component = "backup" })
  backup_policy_arns = {
    service = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
    s3      = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AWSBackupServiceRolePolicyForS3Backup"
  }
  restore_policy_arns = {
    service = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores"
    s3      = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AWSBackupServiceRolePolicyForS3Restore"
  }
  backup_assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowAWSBackup"
      Effect    = "Allow"
      Principal = { Service = "backup.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
      }
    }]
  })
}

resource "aws_kms_key" "backup" {
  description             = "Encrypts ${var.name} AWS Backup recovery points"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "EnableAccountIAMPermissions"
      Effect    = "Allow"
      Principal = { AWS = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root" }
      Action    = "kms:*"
      Resource  = "*"
    }]
  })

  tags = merge(local.common_tags, { Name = "${var.name}-backup" })
}

resource "aws_kms_alias" "backup" {
  name          = "alias/${var.name}-backup"
  target_key_id = aws_kms_key.backup.key_id
}

resource "aws_backup_vault" "this" {
  name          = local.vault_name
  kms_key_arn   = aws_kms_key.backup.arn
  force_destroy = false
  tags          = merge(local.common_tags, { Name = local.vault_name })
}

resource "aws_backup_vault_lock_configuration" "this" {
  backup_vault_name  = aws_backup_vault.this.name
  min_retention_days = var.daily_retention_days
  max_retention_days = var.vault_max_retention_days
}

resource "aws_iam_role" "backup" {
  name               = "${var.name}-backup-service"
  assume_role_policy = local.backup_assume_role_policy
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "backup" {
  for_each   = local.backup_policy_arns
  role       = aws_iam_role.backup.name
  policy_arn = each.value
}

resource "aws_iam_role" "restore" {
  name               = "${var.name}-restore-test"
  assume_role_policy = local.backup_assume_role_policy
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "restore" {
  for_each   = local.restore_policy_arns
  role       = aws_iam_role.restore.name
  policy_arn = each.value
}

resource "aws_backup_plan" "this" {
  name = "${var.name}-data-protection"

  rule {
    rule_name                = "daily"
    target_vault_name        = aws_backup_vault.this.name
    schedule                 = "cron(0 5 ? * * *)"
    start_window             = 60
    completion_window        = 720
    enable_continuous_backup = false

    lifecycle {
      delete_after = var.daily_retention_days
    }

    recovery_point_tags = merge(local.common_tags, { Frequency = "daily" })
  }

  rule {
    rule_name                = "weekly"
    target_vault_name        = aws_backup_vault.this.name
    schedule                 = "cron(0 6 ? * SUN *)"
    start_window             = 60
    completion_window        = 720
    enable_continuous_backup = false

    lifecycle {
      delete_after = var.weekly_retention_days
    }

    recovery_point_tags = merge(local.common_tags, { Frequency = "weekly" })
  }

  tags = local.common_tags
}

resource "aws_backup_selection" "data" {
  name         = "${var.name}-protected-data"
  iam_role_arn = aws_iam_role.backup.arn
  plan_id      = aws_backup_plan.this.id
  resources    = [var.artifact_bucket_arn, var.job_table_arn]
}

resource "aws_backup_restore_testing_plan" "this" {
  count = var.restore_testing_enabled ? 1 : 0

  name                = local.restore_testing_plan_name
  schedule_expression = var.restore_testing_schedule

  recovery_point_selection {
    algorithm             = "LATEST_WITHIN_WINDOW"
    include_vaults        = [aws_backup_vault.this.arn]
    recovery_point_types  = ["SNAPSHOT"]
    selection_window_days = var.daily_retention_days
  }

  tags = local.common_tags
}

resource "aws_backup_restore_testing_selection" "data" {
  for_each = var.restore_testing_enabled ? {
    dynamodb = {
      resource_type = "DynamoDB"
      resource_arn  = var.job_table_arn
    }
    s3 = {
      resource_type = "S3"
      resource_arn  = var.artifact_bucket_arn
    }
  } : {}

  name                      = "${replace(var.name, "-", "_")}_${each.key}_restore"
  restore_testing_plan_name = aws_backup_restore_testing_plan.this[0].name
  protected_resource_type   = each.value.resource_type
  protected_resource_arns   = [each.value.resource_arn]
  iam_role_arn              = aws_iam_role.restore.arn
  validation_window_hours   = 1
}

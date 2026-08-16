variable "name" {
  description = "Lowercase workload name used for backup resources."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$", var.name))
    error_message = "name must be 3-32 lowercase alphanumeric or hyphen characters."
  }
}

variable "artifact_bucket_arn" {
  description = "Concrete ARN of the versioned S3 bucket to protect."
  type        = string

  validation {
    condition     = can(regex("^arn:[^:]+:s3:::[^*]+$", var.artifact_bucket_arn))
    error_message = "artifact_bucket_arn must be one concrete S3 bucket ARN."
  }
}

variable "job_table_arn" {
  description = "Concrete ARN of the DynamoDB table to protect."
  type        = string

  validation {
    condition     = can(regex("^arn:[^:]+:dynamodb:[^:]+:[0-9]{12}:table/[^*]+$", var.job_table_arn))
    error_message = "job_table_arn must be one concrete DynamoDB table ARN."
  }
}

variable "daily_retention_days" {
  description = "Days to retain daily recovery points."
  type        = number
  default     = 35

  validation {
    condition     = var.daily_retention_days >= 35 && floor(var.daily_retention_days) == var.daily_retention_days
    error_message = "daily_retention_days must be an integer of at least 35."
  }
}

variable "weekly_retention_days" {
  description = "Days to retain weekly recovery points."
  type        = number
  default     = 365

  validation {
    condition = (
      var.weekly_retention_days >= 365 &&
      floor(var.weekly_retention_days) == var.weekly_retention_days &&
      var.weekly_retention_days >= var.daily_retention_days &&
      var.weekly_retention_days <= var.vault_max_retention_days
    )
    error_message = "weekly_retention_days must be an integer of at least 365 and satisfy daily <= weekly <= vault maximum."
  }
}

variable "vault_max_retention_days" {
  description = "Largest retention period allowed by the governance-mode vault lock."
  type        = number
  default     = 3650

  validation {
    condition     = var.vault_max_retention_days >= 365 && floor(var.vault_max_retention_days) == var.vault_max_retention_days
    error_message = "vault_max_retention_days must be an integer of at least 365."
  }
}

variable "restore_testing_enabled" {
  description = "Whether to run monthly automated restores of both protected resources."
  type        = bool
  default     = true
}

variable "restore_testing_schedule" {
  description = "EventBridge cron expression for recovery testing."
  type        = string
  default     = "cron(0 8 1 * ? *)"

  validation {
    condition     = can(regex("^cron\\(.+\\)$", var.restore_testing_schedule))
    error_message = "restore_testing_schedule must be an EventBridge cron expression."
  }
}

variable "tags" {
  description = "Tags merged onto supported backup resources."
  type        = map(string)
  default     = {}
}

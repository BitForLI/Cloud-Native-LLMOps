variable "name" {
  description = "Stable lowercase prefix for data resources."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,27}[a-z0-9]$", var.name))
    error_message = "name must be 3-30 lowercase alphanumeric or hyphen characters."
  }
}

variable "kms_key_arn" {
  description = "Optional customer-managed KMS key shared by S3 and DynamoDB."
  type        = string
  default     = null
  nullable    = true
}

variable "artifact_expiration_days" {
  description = "Optional number of days before current artifact versions expire."
  type        = number
  default     = null
  nullable    = true

  validation {
    condition     = var.artifact_expiration_days == null || var.artifact_expiration_days >= 1
    error_message = "artifact_expiration_days must be null or positive."
  }
}

variable "noncurrent_version_retention_days" {
  description = "Days retained for previous artifact versions."
  type        = number
  default     = 30

  validation {
    condition     = var.noncurrent_version_retention_days >= 1
    error_message = "noncurrent_version_retention_days must be positive."
  }
}

variable "abort_incomplete_upload_days" {
  description = "Days before incomplete multipart uploads are aborted."
  type        = number
  default     = 7

  validation {
    condition     = var.abort_incomplete_upload_days >= 1
    error_message = "abort_incomplete_upload_days must be positive."
  }
}

variable "force_destroy_artifacts" {
  description = "Delete objects during bucket destruction; false protects real artifacts."
  type        = bool
  default     = false
}

variable "dynamodb_point_in_time_recovery_enabled" {
  description = "Enable continuous backups for the job table."
  type        = bool
  default     = true
}

variable "dynamodb_deletion_protection_enabled" {
  description = "Protect the job table from deletion. Enable in staging and production."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Additional resource tags."
  type        = map(string)
  default     = {}
}

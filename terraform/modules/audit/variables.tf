variable "name" {
  description = "Stable lowercase prefix for audit resources."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$", var.name))
    error_message = "name must be 3-32 lowercase alphanumeric or hyphen characters."
  }
}

variable "aws_region" {
  description = "Home region for the multi-Region trail and CloudWatch delivery."
  type        = string
}

variable "log_retention_days" {
  description = "Retention for searchable CloudTrail events in CloudWatch Logs."
  type        = number
  default     = 365

  validation {
    condition     = contains([90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days must be a CloudWatch-supported value of at least 90 days."
  }
}

variable "archive_retention_days" {
  description = "Retention for validated audit archives in S3."
  type        = number
  default     = 2557

  validation {
    condition     = var.archive_retention_days >= 365 && floor(var.archive_retention_days) == var.archive_retention_days
    error_message = "archive_retention_days must be an integer of at least 365 days."
  }
}

variable "alarm_topic_arn" {
  description = "Encrypted operational SNS topic for security detections."
  type        = string

  validation {
    condition     = can(regex("^arn:[^:]+:sns:[^:]+:[0-9]{12}:[A-Za-z0-9_-]+$", var.alarm_topic_arn))
    error_message = "alarm_topic_arn must be a concrete SNS topic ARN."
  }
}

variable "tags" {
  description = "Additional resource tags."
  type        = map(string)
  default     = {}
}

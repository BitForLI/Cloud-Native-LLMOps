variable "name" {
  description = "Stable lowercase prefix for queue names."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,47}[a-z0-9]$", var.name))
    error_message = "name must be 3-50 lowercase alphanumeric or hyphen characters."
  }
}

variable "kms_key_arn" {
  description = "Optional customer-managed KMS key; SQS-managed encryption is the default."
  type        = string
  default     = null
  nullable    = true
}

variable "kms_data_key_reuse_period_seconds" {
  description = "KMS data-key reuse period when a customer-managed key is supplied."
  type        = number
  default     = 300

  validation {
    condition     = var.kms_data_key_reuse_period_seconds >= 60 && var.kms_data_key_reuse_period_seconds <= 86400
    error_message = "kms_data_key_reuse_period_seconds must be between 60 and 86400."
  }
}

variable "visibility_timeout_seconds" {
  description = "Time allowed for one inference attempt before redelivery."
  type        = number
  default     = 180

  validation {
    condition     = var.visibility_timeout_seconds >= 30 && var.visibility_timeout_seconds <= 43200
    error_message = "visibility_timeout_seconds must be between 30 and 43200."
  }
}

variable "receive_wait_time_seconds" {
  description = "SQS long-poll duration."
  type        = number
  default     = 20

  validation {
    condition     = var.receive_wait_time_seconds >= 1 && var.receive_wait_time_seconds <= 20
    error_message = "receive_wait_time_seconds must be between 1 and 20."
  }
}

variable "message_retention_seconds" {
  description = "Retention period for unprocessed inference messages."
  type        = number
  default     = 345600

  validation {
    condition     = var.message_retention_seconds >= 60 && var.message_retention_seconds <= 1209600
    error_message = "message_retention_seconds must be between 60 and 1209600."
  }
}

variable "dead_letter_retention_seconds" {
  description = "DLQ retention, normally longer than the source queue."
  type        = number
  default     = 1209600

  validation {
    condition     = var.dead_letter_retention_seconds >= var.message_retention_seconds && var.dead_letter_retention_seconds <= 1209600
    error_message = "dead_letter_retention_seconds must be at least source retention and no more than 1209600."
  }
}

variable "max_receive_count" {
  description = "Failed receives allowed before a message moves to the DLQ."
  type        = number
  default     = 5

  validation {
    condition     = var.max_receive_count >= 1 && var.max_receive_count <= 1000
    error_message = "max_receive_count must be between 1 and 1000."
  }
}

variable "max_message_size_bytes" {
  description = "Maximum queue payload size; prompts should stay well below this bound."
  type        = number
  default     = 65536

  validation {
    condition     = var.max_message_size_bytes >= 1024 && var.max_message_size_bytes <= 1048576
    error_message = "max_message_size_bytes must be between 1024 and 1048576."
  }
}

variable "tags" {
  description = "Additional resource tags."
  type        = map(string)
  default     = {}
}

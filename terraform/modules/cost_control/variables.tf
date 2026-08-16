variable "name" {
  description = "Stable project and environment prefix for cost controls."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,62}[a-z0-9]$", var.name))
    error_message = "name must be 3-64 lowercase alphanumeric or hyphen characters."
  }
}

variable "monthly_budget_limit_usd" {
  description = "Account-level monthly production budget in USD."
  type        = number

  validation {
    condition     = var.monthly_budget_limit_usd > 0 && var.monthly_budget_limit_usd <= 1000000
    error_message = "monthly_budget_limit_usd must be greater than zero and at most 1,000,000."
  }
}

variable "notification_topic_arn" {
  description = "Same-account SNS topic receiving actual and forecast budget alerts."
  type        = string

  validation {
    condition     = can(regex("^arn:[^:]+:sns:[^:]+:[0-9]{12}:[A-Za-z0-9_-]+$", var.notification_topic_arn))
    error_message = "notification_topic_arn must be a concrete SNS topic ARN."
  }
}

variable "actual_alert_threshold_percent" {
  description = "Actual monthly spend percentage that triggers an alert."
  type        = number
  default     = 80

  validation {
    condition     = var.actual_alert_threshold_percent > 0 && var.actual_alert_threshold_percent <= 100
    error_message = "actual_alert_threshold_percent must be greater than zero and at most 100."
  }
}

variable "forecast_alert_threshold_percent" {
  description = "Forecast monthly spend percentage that triggers an alert."
  type        = number
  default     = 100

  validation {
    condition     = var.forecast_alert_threshold_percent > 0 && var.forecast_alert_threshold_percent <= 100
    error_message = "forecast_alert_threshold_percent must be greater than zero and at most 100."
  }
}

variable "tags" {
  description = "Additional resource tags."
  type        = map(string)
  default     = {}
}

variable "name" {
  description = "Stable prefix for monitoring resources."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9_-]{2,63}$", var.name))
    error_message = "name must be 3-64 alphanumeric, hyphen, or underscore characters."
  }
}

variable "environment" {
  description = "Environment dimension attached to application metrics."
  type        = string
}

variable "aws_region" {
  description = "AWS region used by dashboard widgets and scoped policies."
  type        = string
}

variable "cluster_name" {
  description = "ECS cluster monitored for service saturation."
  type        = string
}

variable "api_service_name" {
  description = "API ECS service name."
  type        = string
}

variable "worker_service_name" {
  description = "Worker ECS service name."
  type        = string
}

variable "load_balancer_arn_suffix" {
  description = "ALB CloudWatch LoadBalancer dimension value."
  type        = string
}

variable "target_group_arn_suffix" {
  description = "ALB CloudWatch TargetGroup dimension value."
  type        = string
}

variable "alternate_target_group_arn_suffix" {
  description = "Optional alternate ALB target group monitored during blue/green releases."
  type        = string
  default     = null
  nullable    = true
}

variable "monitor_alternate_target_group" {
  description = "Create release alarms for the alternate blue/green target group."
  type        = bool
  default     = false
}

variable "waf_enabled" {
  description = "Include regional WAF blocked traffic in the operations dashboard."
  type        = bool
  default     = false
}

variable "waf_web_acl_metric_name" {
  description = "WebACL CloudWatch dimension configured by WAF visibility settings."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.waf_web_acl_metric_name == null || can(regex("^[A-Za-z0-9]+$", var.waf_web_acl_metric_name))
    error_message = "waf_web_acl_metric_name must be null or alphanumeric."
  }
}

variable "evaluation_monitoring_enabled" {
  description = "Monitor the daily production evaluation gate and alert when it fails or stops reporting."
  type        = bool
  default     = false
}

variable "evaluation_accuracy_threshold" {
  description = "Minimum acceptable continuous evaluation accuracy ratio."
  type        = number
  default     = 0.90

  validation {
    condition     = var.evaluation_accuracy_threshold > 0 && var.evaluation_accuracy_threshold <= 1
    error_message = "evaluation_accuracy_threshold must be greater than 0 and at most 1."
  }
}

variable "budget_notifications_enabled" {
  description = "Allow same-account AWS Budgets to publish into the encrypted alarm topic."
  type        = bool
  default     = false
}

variable "llm_hourly_cost_threshold_usd" {
  description = "Optional combined API and Worker estimated LLM cost per hour alarm threshold."
  type        = number
  default     = null
  nullable    = true

  validation {
    condition     = var.llm_hourly_cost_threshold_usd == null || var.llm_hourly_cost_threshold_usd > 0
    error_message = "llm_hourly_cost_threshold_usd must be null or greater than zero."
  }
}

variable "queue_name" {
  description = "Inference queue CloudWatch dimension value."
  type        = string
}

variable "dead_letter_queue_name" {
  description = "Dead-letter queue CloudWatch dimension value."
  type        = string
}

variable "api_log_group_name" {
  description = "API log group used by metric filters and Logs Insights."
  type        = string
}

variable "worker_log_group_name" {
  description = "Worker log group used by Logs Insights."
  type        = string
}

variable "bedrock_model_id" {
  description = "Model dimension emitted by API and Worker EMF events."
  type        = string
}

variable "notification_emails" {
  description = "Email endpoints that must confirm SNS alarm subscriptions."
  type        = set(string)
  default     = []

  validation {
    condition = alltrue([
      for email in var.notification_emails :
      can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", email))
    ])
    error_message = "notification_emails must contain syntactically valid email addresses."
  }
}

variable "error_rate_threshold_percent" {
  description = "Maximum acceptable ALB and model error rate."
  type        = number
  default     = 5

  validation {
    condition     = var.error_rate_threshold_percent > 0 && var.error_rate_threshold_percent <= 100
    error_message = "error_rate_threshold_percent must be greater than 0 and at most 100."
  }
}

variable "p95_latency_threshold_ms" {
  description = "Maximum acceptable HTTP and LLM P95 latency."
  type        = number
  default     = 3000

  validation {
    condition     = var.p95_latency_threshold_ms > 0
    error_message = "p95_latency_threshold_ms must be positive."
  }
}

variable "resource_utilization_threshold_percent" {
  description = "Maximum sustained ECS CPU or memory utilization."
  type        = number
  default     = 80

  validation {
    condition     = var.resource_utilization_threshold_percent > 0 && var.resource_utilization_threshold_percent <= 100
    error_message = "resource_utilization_threshold_percent must be greater than 0 and at most 100."
  }
}

variable "queue_age_threshold_seconds" {
  description = "Maximum age of the oldest pending inference message."
  type        = number
  default     = 300

  validation {
    condition     = var.queue_age_threshold_seconds >= 60
    error_message = "queue_age_threshold_seconds must be at least 60."
  }
}

variable "tags" {
  description = "Additional resource tags."
  type        = map(string)
  default     = {}
}

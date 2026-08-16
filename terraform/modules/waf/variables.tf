variable "enabled" {
  description = "Whether to create and associate the regional WAF boundary."
  type        = bool
  default     = true
}

variable "name" {
  description = "Stable lowercase name for WAF resources and metrics."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$", var.name))
    error_message = "name must be 3-32 lowercase alphanumeric or hyphen characters."
  }
}

variable "aws_region" {
  description = "Region containing the protected ALB."
  type        = string

  validation {
    condition     = can(regex("^[a-z]{2}(?:-gov)?-[a-z]+-[0-9]+$", var.aws_region))
    error_message = "aws_region must be a valid AWS region name."
  }
}

variable "alb_arn" {
  description = "Concrete regional ALB ARN associated with the Web ACL."
  type        = string

  validation {
    condition     = can(regex("^arn:[^:]+:elasticloadbalancing:[^:]+:[0-9]{12}:loadbalancer/app/[^*]+$", var.alb_arn))
    error_message = "alb_arn must be a concrete application load balancer ARN."
  }
}

variable "rate_limit_per_five_minutes" {
  description = "Maximum requests accepted from one source IP in a five-minute window."
  type        = number
  default     = 1000

  validation {
    condition     = var.rate_limit_per_five_minutes >= 100 && var.rate_limit_per_five_minutes <= 1000000 && floor(var.rate_limit_per_five_minutes) == var.rate_limit_per_five_minutes
    error_message = "rate_limit_per_five_minutes must be an integer between 100 and 1000000."
  }
}

variable "blocked_request_alarm_threshold" {
  description = "Blocked requests in five minutes that trigger the security alarm."
  type        = number
  default     = 100

  validation {
    condition     = var.blocked_request_alarm_threshold >= 1 && floor(var.blocked_request_alarm_threshold) == var.blocked_request_alarm_threshold
    error_message = "blocked_request_alarm_threshold must be a positive integer."
  }
}

variable "alarm_topic_arn" {
  description = "SNS topic notified when WAF blocking volume becomes abnormal."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.alarm_topic_arn == null || can(regex("^arn:[^:]+:sns:[^:]+:[0-9]{12}:[^*]+$", var.alarm_topic_arn))
    error_message = "alarm_topic_arn must be null or a concrete SNS topic ARN."
  }
}

variable "log_retention_days" {
  description = "Retention for blocked-request WAF logs."
  type        = number
  default     = 90

  validation {
    condition     = contains([30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days must be a supported value of at least 30 days."
  }
}

variable "tags" {
  description = "Additional resource tags."
  type        = map(string)
  default     = {}
}

variable "aws_region" {
  description = "AWS region for the production stack."
  type        = string
  default     = "ap-southeast-2"

  validation {
    condition     = can(regex("^[a-z]{2}(?:-gov)?-[a-z]+-[0-9]+$", var.aws_region))
    error_message = "aws_region must be a valid AWS region name."
  }
}

variable "project_name" {
  description = "Lowercase project identifier used in names and tags."
  type        = string
  default     = "cloud-native-llmops"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,25}[a-z0-9]$", var.project_name))
    error_message = "project_name must be 3-27 lowercase alphanumeric or hyphen characters."
  }
}

variable "environment" {
  description = "Fixed production environment name."
  type        = string
  default     = "production"

  validation {
    condition     = var.environment == "production"
    error_message = "This root module is reserved for production."
  }
}

variable "vpc_cidr" {
  description = "CIDR for the isolated production VPC."
  type        = string
  default     = "10.40.0.0/16"

  validation {
    condition = can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}/[0-9]{1,2}$", var.vpc_cidr)) && try(
      tonumber(split("/", var.vpc_cidr)[1]) >= 16 &&
      tonumber(split("/", var.vpc_cidr)[1]) <= 24 &&
      cidrsubnet(var.vpc_cidr, 4, 10) != "",
      false
    )
    error_message = "vpc_cidr must be a valid IPv4 /16-/24 CIDR."
  }
}

variable "availability_zone_count" {
  description = "Production availability-zone count."
  type        = number
  default     = 3

  validation {
    condition     = var.availability_zone_count >= 2 && var.availability_zone_count <= 3
    error_message = "availability_zone_count must be 2 or 3."
  }
}

variable "availability_zones" {
  description = "Optional explicit list of two or three distinct zones."
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.availability_zones) == 0 || (length(var.availability_zones) >= 2 && length(var.availability_zones) <= 3)
    error_message = "availability_zones must be empty or contain 2-3 zones."
  }

  validation {
    condition     = length(distinct(var.availability_zones)) == length(var.availability_zones)
    error_message = "availability_zones must not contain duplicates."
  }
}

variable "job_visibility_timeout_seconds" {
  description = "Time allowed for one production Worker attempt."
  type        = number
  default     = 180

  validation {
    condition     = var.job_visibility_timeout_seconds >= 30 && var.job_visibility_timeout_seconds <= 43200
    error_message = "job_visibility_timeout_seconds must be between 30 and 43200."
  }
}

variable "job_max_receive_count" {
  description = "Failed receives before a job moves to the DLQ."
  type        = number
  default     = 5

  validation {
    condition     = var.job_max_receive_count >= 1 && var.job_max_receive_count <= 1000
    error_message = "job_max_receive_count must be between 1 and 1000."
  }
}

variable "bedrock_model_id" {
  description = "Concrete Bedrock model allowed in production."
  type        = string
  default     = "anthropic.claude-3-haiku-20240307-v1:0"

  validation {
    condition     = length(trimspace(var.bedrock_model_id)) > 0 && !strcontains(var.bedrock_model_id, "*")
    error_message = "bedrock_model_id must be concrete and cannot contain wildcards."
  }
}

variable "github_oidc_provider_arn" {
  description = "Existing account-level GitHub OIDC provider ARN."
  type        = string

  validation {
    condition     = can(regex("^arn:[^:]+:iam::[0-9]{12}:oidc-provider/token\\.actions\\.githubusercontent\\.com$", var.github_oidc_provider_arn))
    error_message = "github_oidc_provider_arn must identify the account GitHub Actions provider."
  }
}

variable "github_oidc_subjects" {
  description = "Exact GitHub production environment subject."
  type        = set(string)
  default     = ["repo:BitForLI@218609705/Cloud-Native-LLMOps@1320235086:environment:production"]

  validation {
    condition = length(var.github_oidc_subjects) == 1 && alltrue([
      for subject in var.github_oidc_subjects : endswith(subject, ":environment:production") && !strcontains(subject, "*")
    ])
    error_message = "Production requires one exact environment:production OIDC subject."
  }
}

variable "github_evaluation_oidc_subjects" {
  description = "Exact GitHub OIDC identity for the non-deployment production monitoring environment."
  type        = set(string)
  default     = ["repo:BitForLI@218609705/Cloud-Native-LLMOps@1320235086:environment:production-monitoring"]

  validation {
    condition = length(var.github_evaluation_oidc_subjects) == 1 && alltrue([
      for subject in var.github_evaluation_oidc_subjects : endswith(subject, ":environment:production-monitoring") && !strcontains(subject, "*")
    ])
    error_message = "Production evaluation must trust exactly one protected production-monitoring environment identity."
  }
}

variable "promotion_source_ecr_repository_arns" {
  description = "Concrete staging ECR repositories permitted as promotion sources."
  type        = set(string)

  validation {
    condition = length(var.promotion_source_ecr_repository_arns) == 2 && alltrue([
      for arn in var.promotion_source_ecr_repository_arns : can(regex("^arn:[^:]+:ecr:[^:]+:[0-9]{12}:repository/.+/staging/(api|worker)$", arn))
    ])
    error_message = "Provide exactly the staging API and Worker ECR repository ARNs."
  }
}

variable "alb_certificate_arn" {
  description = "ACM certificate required by the production HTTPS listener."
  type        = string

  validation {
    condition     = can(regex("^arn:[^:]+:acm:[^:]+:[0-9]{12}:certificate/", var.alb_certificate_arn))
    error_message = "alb_certificate_arn must be a concrete ACM certificate ARN."
  }
}

variable "api_image_tag" {
  description = "Immutable bootstrap API image tag."
  type        = string
  default     = "bootstrap"

  validation {
    condition     = var.api_image_tag != "latest" && can(regex("^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$", var.api_image_tag))
    error_message = "api_image_tag must be valid and cannot be latest."
  }
}

variable "worker_image_tag" {
  description = "Immutable bootstrap Worker image tag."
  type        = string
  default     = "bootstrap"

  validation {
    condition     = var.worker_image_tag != "latest" && can(regex("^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$", var.worker_image_tag))
    error_message = "worker_image_tag must be valid and cannot be latest."
  }
}

variable "api_desired_count" {
  description = "Production API task count."
  type        = number
  default     = 3

  validation {
    condition     = var.api_desired_count >= 2 && floor(var.api_desired_count) == var.api_desired_count
    error_message = "Production requires at least two API tasks."
  }
}

variable "worker_desired_count" {
  description = "Production Worker task count."
  type        = number
  default     = 2

  validation {
    condition     = var.worker_desired_count >= 2 && floor(var.worker_desired_count) == var.worker_desired_count
    error_message = "Production requires at least two Worker tasks."
  }
}

variable "api_max_capacity" {
  description = "Maximum API tasks allowed by production autoscaling."
  type        = number
  default     = 12

  validation {
    condition     = var.api_max_capacity >= 2 && floor(var.api_max_capacity) == var.api_max_capacity
    error_message = "Production API maximum capacity must be an integer of at least two."
  }
}

variable "worker_max_capacity" {
  description = "Maximum Worker tasks allowed by production autoscaling."
  type        = number
  default     = 30

  validation {
    condition     = var.worker_max_capacity >= 2 && floor(var.worker_max_capacity) == var.worker_max_capacity
    error_message = "Production Worker maximum capacity must be an integer of at least two."
  }
}

variable "worker_backlog_target_per_task" {
  description = "Visible inference jobs targeted per running production Worker."
  type        = number
  default     = 2

  validation {
    condition     = var.worker_backlog_target_per_task > 0 && var.worker_backlog_target_per_task <= 1000
    error_message = "worker_backlog_target_per_task must be greater than zero and at most 1000."
  }
}

variable "log_retention_days" {
  description = "Production CloudWatch Logs retention."
  type        = number
  default     = 365

  validation {
    condition     = contains([365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "Production log retention must be at least 365 days."
  }
}

variable "otel_trace_sample_ratio" {
  description = "Production root-trace sampling ratio; parent decisions are preserved."
  type        = number
  default     = 0.1

  validation {
    condition     = var.otel_trace_sample_ratio >= 0 && var.otel_trace_sample_ratio <= 1
    error_message = "otel_trace_sample_ratio must be between 0 and 1."
  }
}

variable "blue_termination_wait_minutes" {
  description = "Post-shift bake period before blue API tasks terminate."
  type        = number
  default     = 10

  validation {
    condition     = var.blue_termination_wait_minutes >= 5 && var.blue_termination_wait_minutes <= 60
    error_message = "Production blue bake time must be between 5 and 60 minutes."
  }
}

variable "waf_rate_limit_per_five_minutes" {
  description = "Production WAF request ceiling per source IP over five minutes."
  type        = number
  default     = 5000

  validation {
    condition     = var.waf_rate_limit_per_five_minutes >= 100 && var.waf_rate_limit_per_five_minutes <= 1000000 && floor(var.waf_rate_limit_per_five_minutes) == var.waf_rate_limit_per_five_minutes
    error_message = "waf_rate_limit_per_five_minutes must be an integer between 100 and 1000000."
  }
}

variable "waf_blocked_request_alarm_threshold" {
  description = "Blocked production requests in five minutes that trigger an alarm."
  type        = number
  default     = 250

  validation {
    condition     = var.waf_blocked_request_alarm_threshold >= 1 && floor(var.waf_blocked_request_alarm_threshold) == var.waf_blocked_request_alarm_threshold
    error_message = "waf_blocked_request_alarm_threshold must be a positive integer."
  }
}

variable "alarm_notification_emails" {
  description = "Confirmed production alarm recipients."
  type        = set(string)

  validation {
    condition     = length(var.alarm_notification_emails) > 0
    error_message = "Production requires at least one alarm recipient."
  }
}

variable "alarm_error_rate_threshold_percent" {
  description = "Maximum production HTTP/model error rate."
  type        = number
  default     = 5
}

variable "alarm_p95_latency_threshold_ms" {
  description = "Maximum production P95 latency."
  type        = number
  default     = 3000
}

variable "alarm_queue_age_threshold_seconds" {
  description = "Maximum age of pending production inference work."
  type        = number
  default     = 300
}

variable "alarm_resource_utilization_threshold_percent" {
  description = "Maximum sustained production ECS utilization."
  type        = number
  default     = 80
}

variable "monthly_budget_limit_usd" {
  description = "Monthly AWS account cost budget for the production workload."
  type        = number
  default     = 100

  validation {
    condition     = var.monthly_budget_limit_usd > 0 && var.monthly_budget_limit_usd <= 1000000
    error_message = "monthly_budget_limit_usd must be greater than zero and at most 1,000,000."
  }
}

variable "alarm_llm_hourly_cost_threshold_usd" {
  description = "Combined estimated Bedrock cost per hour that triggers an operational alarm."
  type        = number
  default     = 10

  validation {
    condition     = var.alarm_llm_hourly_cost_threshold_usd > 0 && var.alarm_llm_hourly_cost_threshold_usd <= var.monthly_budget_limit_usd
    error_message = "alarm_llm_hourly_cost_threshold_usd must be positive and no greater than the monthly budget."
  }
}

variable "audit_archive_retention_days" {
  description = "Retention for encrypted, validated CloudTrail archives."
  type        = number
  default     = 2557

  validation {
    condition     = var.audit_archive_retention_days >= 365 && floor(var.audit_archive_retention_days) == var.audit_archive_retention_days
    error_message = "audit_archive_retention_days must be an integer of at least 365 days."
  }
}

variable "backup_daily_retention_days" {
  description = "Retention for daily S3 and DynamoDB recovery points."
  type        = number
  default     = 35

  validation {
    condition     = var.backup_daily_retention_days >= 35 && floor(var.backup_daily_retention_days) == var.backup_daily_retention_days
    error_message = "backup_daily_retention_days must be an integer of at least 35 days."
  }
}

variable "backup_weekly_retention_days" {
  description = "Retention for weekly S3 and DynamoDB recovery points."
  type        = number
  default     = 365

  validation {
    condition     = var.backup_weekly_retention_days >= 365 && var.backup_weekly_retention_days >= var.backup_daily_retention_days && var.backup_weekly_retention_days <= 3650 && floor(var.backup_weekly_retention_days) == var.backup_weekly_retention_days
    error_message = "backup_weekly_retention_days must be an integer from 365 through 3650 and no shorter than daily retention."
  }
}

variable "backup_restore_testing_enabled" {
  description = "Production invariant requiring monthly automated S3 and DynamoDB restore tests."
  type        = bool
  default     = true

  validation {
    condition     = var.backup_restore_testing_enabled
    error_message = "Production automated restore testing cannot be disabled."
  }
}

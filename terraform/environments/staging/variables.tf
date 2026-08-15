variable "aws_region" {
  description = "AWS region for the staging stack."
  type        = string
  default     = "ap-southeast-2"
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
  description = "Deployment environment name."
  type        = string
  default     = "staging"

  validation {
    condition     = var.environment == "staging"
    error_message = "This root module is reserved for staging."
  }
}

variable "vpc_cidr" {
  description = "CIDR for the isolated staging VPC."
  type        = string
  default     = "10.30.0.0/16"

  validation {
    condition = can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}/[0-9]{1,2}$", var.vpc_cidr)) && try(
      tonumber(split("/", var.vpc_cidr)[1]) >= 16 &&
      tonumber(split("/", var.vpc_cidr)[1]) <= 24 &&
      cidrsubnet(var.vpc_cidr, 4, 10) != "",
      false
    )
    error_message = "vpc_cidr must be a valid IPv4 /16-/24 CIDR with room for derived subnets."
  }
}

variable "availability_zone_count" {
  description = "Number of zones used when availability_zones is empty."
  type        = number
  default     = 2

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

variable "nat_gateway_mode" {
  description = "Staging defaults to one NAT gateway per availability zone."
  type        = string
  default     = "per_az"

  validation {
    condition     = var.nat_gateway_mode == "per_az"
    error_message = "Staging requires per_az NAT gateways."
  }
}

variable "job_visibility_timeout_seconds" {
  description = "Time allowed for a Worker attempt before SQS redelivery."
  type        = number
  default     = 180

  validation {
    condition     = var.job_visibility_timeout_seconds >= 30 && var.job_visibility_timeout_seconds <= 43200
    error_message = "job_visibility_timeout_seconds must be between 30 and 43200."
  }
}

variable "job_max_receive_count" {
  description = "Failed receives allowed before a job moves to the DLQ."
  type        = number
  default     = 5

  validation {
    condition     = var.job_max_receive_count >= 1 && var.job_max_receive_count <= 1000
    error_message = "job_max_receive_count must be between 1 and 1000."
  }
}

variable "bedrock_model_id" {
  description = "Concrete Bedrock model allowed in staging."
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
  description = "Exact GitHub environment subject permitted to promote staging."
  type        = set(string)
  default     = ["repo:BitForLI@218609705/Cloud-Native-LLMOps@1320235086:environment:staging"]

  validation {
    condition = length(var.github_oidc_subjects) == 1 && alltrue([
      for subject in var.github_oidc_subjects : endswith(subject, ":environment:staging") && !strcontains(subject, "*")
    ])
    error_message = "Staging requires one exact environment:staging OIDC subject without wildcards."
  }
}

variable "promotion_source_ecr_repository_arns" {
  description = "Concrete dev ECR repository ARNs allowed as promotion sources."
  type        = set(string)

  validation {
    condition = length(var.promotion_source_ecr_repository_arns) == 2 && alltrue([
      for arn in var.promotion_source_ecr_repository_arns : can(regex("^arn:[^:]+:ecr:[^:]+:[0-9]{12}:repository/.+/dev/(api|worker)$", arn))
    ])
    error_message = "Provide exactly the dev API and Worker ECR repository ARNs."
  }
}

variable "alb_certificate_arn" {
  description = "ACM certificate required for the staging HTTPS endpoint."
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
  description = "Staging API task count."
  type        = number
  default     = 2

  validation {
    condition     = var.api_desired_count >= 2 && floor(var.api_desired_count) == var.api_desired_count
    error_message = "Staging requires at least two API tasks."
  }
}

variable "worker_desired_count" {
  description = "Staging Worker task count."
  type        = number
  default     = 2

  validation {
    condition     = var.worker_desired_count >= 2 && floor(var.worker_desired_count) == var.worker_desired_count
    error_message = "Staging requires at least two Worker tasks."
  }
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for staging services."
  type        = number
  default     = 90

  validation {
    condition     = contains([90, 120, 150, 180, 365, 400, 545, 731], var.log_retention_days)
    error_message = "Staging log retention must be at least 90 days."
  }
}

variable "otel_trace_sample_ratio" {
  description = "Staging root-trace sampling ratio used for release verification."
  type        = number
  default     = 1

  validation {
    condition     = var.otel_trace_sample_ratio >= 0 && var.otel_trace_sample_ratio <= 1
    error_message = "otel_trace_sample_ratio must be between 0 and 1."
  }
}

variable "alarm_notification_emails" {
  description = "Addresses that receive staging alarm transitions."
  type        = set(string)
  default     = []
}

variable "alarm_error_rate_threshold_percent" {
  type    = number
  default = 5
}

variable "alarm_p95_latency_threshold_ms" {
  type    = number
  default = 3000
}

variable "alarm_queue_age_threshold_seconds" {
  type    = number
  default = 300
}

variable "alarm_resource_utilization_threshold_percent" {
  type    = number
  default = 80
}

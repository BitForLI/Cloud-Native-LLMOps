variable "aws_region" {
  description = "AWS region in which the development stack is created."
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
  default     = "dev"

  validation {
    condition     = var.environment == "dev"
    error_message = "This root module is reserved for the dev environment."
  }
}

variable "vpc_cidr" {
  description = "CIDR for the development VPC."
  type        = string
  default     = "10.20.0.0/16"

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
  description = "Number of zones selected when availability_zones is empty."
  type        = number
  default     = 2

  validation {
    condition     = var.availability_zone_count >= 2 && var.availability_zone_count <= 3
    error_message = "availability_zone_count must be 2 or 3."
  }
}

variable "availability_zones" {
  description = "Optional explicit zone list, such as ap-southeast-2a and 2b."
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
  description = "Development defaults to one shared NAT gateway to limit cost."
  type        = string
  default     = "single"

  validation {
    condition     = contains(["none", "single", "per_az"], var.nat_gateway_mode)
    error_message = "nat_gateway_mode must be none, single, or per_az."
  }
}

variable "job_visibility_timeout_seconds" {
  description = "Time allowed for one Worker inference attempt before SQS redelivery."
  type        = number
  default     = 180

  validation {
    condition     = var.job_visibility_timeout_seconds >= 30 && var.job_visibility_timeout_seconds <= 43200
    error_message = "job_visibility_timeout_seconds must be between 30 and 43200."
  }
}

variable "job_max_receive_count" {
  description = "Failed receives allowed before an inference job moves to the DLQ."
  type        = number
  default     = 5

  validation {
    condition     = var.job_max_receive_count >= 1 && var.job_max_receive_count <= 1000
    error_message = "job_max_receive_count must be between 1 and 1000."
  }
}

variable "bedrock_model_id" {
  description = "Bedrock foundation model runtime roles may invoke."
  type        = string
  default     = "anthropic.claude-3-haiku-20240307-v1:0"

  validation {
    condition     = length(trimspace(var.bedrock_model_id)) > 0 && !strcontains(var.bedrock_model_id, "*")
    error_message = "bedrock_model_id must be concrete and must not contain wildcards."
  }
}

variable "github_oidc_provider_arn" {
  description = "Existing account-level GitHub OIDC provider ARN; null creates it."
  type        = string
  default     = null
  nullable    = true
}

variable "github_oidc_subjects" {
  description = "Exact GitHub OIDC subjects permitted to deploy this environment."
  type        = set(string)
  default = [
    "repo:BitForLI@218609705/Cloud-Native-LLMOps@1320235086:ref:refs/heads/master"
  ]

  validation {
    condition     = length(var.github_oidc_subjects) > 0 && alltrue([for subject in var.github_oidc_subjects : startswith(subject, "repo:") && !strcontains(subject, "*")])
    error_message = "github_oidc_subjects must contain exact repo: subjects without wildcards."
  }
}

variable "alb_certificate_arn" {
  description = "Optional ACM certificate for HTTPS; null leaves dev on HTTP."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.alb_certificate_arn == null || can(regex("^arn:[^:]+:acm:[^:]+:[0-9]{12}:certificate/", var.alb_certificate_arn))
    error_message = "alb_certificate_arn must be null or a concrete ACM certificate ARN."
  }
}

variable "api_image_tag" {
  description = "Immutable API image tag that must already exist before ECS apply."
  type        = string
  default     = "bootstrap"

  validation {
    condition     = var.api_image_tag != "latest" && can(regex("^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$", var.api_image_tag))
    error_message = "api_image_tag must be a valid immutable tag and cannot be latest."
  }
}

variable "worker_image_tag" {
  description = "Immutable Worker image tag that must already exist before ECS apply."
  type        = string
  default     = "bootstrap"

  validation {
    condition     = var.worker_image_tag != "latest" && can(regex("^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$", var.worker_image_tag))
    error_message = "worker_image_tag must be a valid immutable tag and cannot be latest."
  }
}

variable "api_desired_count" {
  description = "Number of API tasks in development."
  type        = number
  default     = 1
}

variable "worker_desired_count" {
  description = "Number of Worker tasks in development."
  type        = number
  default     = 1
}

variable "log_retention_days" {
  description = "CloudWatch container log retention."
  type        = number
  default     = 30
}

variable "otel_trace_sample_ratio" {
  description = "Development root-trace sampling ratio."
  type        = number
  default     = 1

  validation {
    condition     = var.otel_trace_sample_ratio >= 0 && var.otel_trace_sample_ratio <= 1
    error_message = "otel_trace_sample_ratio must be between 0 and 1."
  }
}

variable "alarm_notification_emails" {
  description = "Email addresses that confirm and receive CloudWatch alarm notifications."
  type        = set(string)
  default     = []
}

variable "alarm_error_rate_threshold_percent" {
  description = "Maximum acceptable HTTP and model error rate."
  type        = number
  default     = 5
}

variable "alarm_p95_latency_threshold_ms" {
  description = "Maximum acceptable P95 HTTP and LLM latency."
  type        = number
  default     = 3000
}

variable "alarm_queue_age_threshold_seconds" {
  description = "Maximum age of the oldest pending inference message."
  type        = number
  default     = 300
}

variable "alarm_resource_utilization_threshold_percent" {
  description = "Maximum sustained ECS CPU or memory utilization."
  type        = number
  default     = 80
}

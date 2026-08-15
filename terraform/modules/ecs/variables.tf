variable "name" {
  description = "Stable lowercase name for the cluster, services, and task families."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$", var.name))
    error_message = "name must be 3-32 lowercase alphanumeric or hyphen characters."
  }
}

variable "environment" {
  description = "Application environment injected into both containers."
  type        = string

  validation {
    condition     = length(trimspace(var.environment)) > 0
    error_message = "environment must not be empty."
  }
}

variable "aws_region" {
  description = "AWS region used by SDKs and the awslogs driver."
  type        = string

  validation {
    condition     = can(regex("^[a-z]{2}(?:-gov)?-[a-z]+-[0-9]+$", var.aws_region))
    error_message = "aws_region must be a valid AWS region name."
  }
}

variable "vpc_id" {
  description = "VPC containing the Fargate tasks."
  type        = string
}

variable "private_subnet_ids" {
  description = "At least two private subnets used by both ECS services."
  type        = list(string)

  validation {
    condition     = length(distinct(var.private_subnet_ids)) >= 2
    error_message = "private_subnet_ids must contain at least two distinct subnets."
  }
}

variable "alb_security_group_id" {
  description = "ALB security group allowed to reach the API container port."
  type        = string
}

variable "api_target_group_arn" {
  description = "ALB target group attached to the API ECS service."
  type        = string

  validation {
    condition     = can(regex("^arn:[^:]+:elasticloadbalancing:[^:]+:[0-9]{12}:targetgroup/[^*]+$", var.api_target_group_arn))
    error_message = "api_target_group_arn must be a concrete ALB target-group ARN."
  }
}

variable "api_repository_url" {
  description = "ECR repository URL without an image tag."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}\\.dkr\\.ecr\\.[a-z0-9-]+\\.amazonaws\\.com(?:\\.cn)?/[A-Za-z0-9._/-]+$", var.api_repository_url)) && !strcontains(var.api_repository_url, "@")
    error_message = "api_repository_url must be an untagged ECR repository URL."
  }
}

variable "worker_repository_url" {
  description = "Worker ECR repository URL without an image tag."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}\\.dkr\\.ecr\\.[a-z0-9-]+\\.amazonaws\\.com(?:\\.cn)?/[A-Za-z0-9._/-]+$", var.worker_repository_url)) && !strcontains(var.worker_repository_url, "@")
    error_message = "worker_repository_url must be an untagged ECR repository URL."
  }
}

variable "api_image_tag" {
  description = "Immutable API image tag already present in ECR."
  type        = string
  default     = "bootstrap"

  validation {
    condition     = var.api_image_tag != "latest" && can(regex("^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$", var.api_image_tag))
    error_message = "api_image_tag must be a valid immutable tag and cannot be latest."
  }
}

variable "worker_image_tag" {
  description = "Immutable Worker image tag already present in ECR."
  type        = string
  default     = "bootstrap"

  validation {
    condition     = var.worker_image_tag != "latest" && can(regex("^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$", var.worker_image_tag))
    error_message = "worker_image_tag must be a valid immutable tag and cannot be latest."
  }
}

variable "execution_role_arn" {
  description = "ECS execution role for image pulls and log delivery."
  type        = string

  validation {
    condition     = can(regex("^arn:[^:]+:iam::[0-9]{12}:role/[^*]+$", var.execution_role_arn))
    error_message = "execution_role_arn must be a concrete IAM role ARN."
  }
}

variable "api_task_role_arn" {
  description = "Runtime role used only by the API task."
  type        = string

  validation {
    condition     = can(regex("^arn:[^:]+:iam::[0-9]{12}:role/[^*]+$", var.api_task_role_arn))
    error_message = "api_task_role_arn must be a concrete IAM role ARN."
  }
}

variable "worker_task_role_arn" {
  description = "Runtime role used only by the Worker task."
  type        = string

  validation {
    condition     = can(regex("^arn:[^:]+:iam::[0-9]{12}:role/[^*]+$", var.worker_task_role_arn))
    error_message = "worker_task_role_arn must be a concrete IAM role ARN."
  }
}

variable "bedrock_model_id" {
  description = "Bedrock model selected by the services."
  type        = string

  validation {
    condition     = length(trimspace(var.bedrock_model_id)) > 0 && !strcontains(var.bedrock_model_id, "*")
    error_message = "bedrock_model_id must be concrete and non-empty."
  }
}

variable "artifact_bucket_name" {
  description = "S3 artifact bucket name exposed to future durable adapters."
  type        = string
}

variable "job_table_name" {
  description = "DynamoDB job table name exposed to future durable adapters."
  type        = string
}

variable "inference_queue_url" {
  description = "SQS inference queue URL exposed to future durable adapters."
  type        = string
}

variable "api_container_port" {
  description = "API container and target-group port."
  type        = number
  default     = 8000

  validation {
    condition     = var.api_container_port >= 1 && var.api_container_port <= 65535
    error_message = "api_container_port must be a valid TCP port."
  }
}

variable "api_cpu" {
  description = "Fargate CPU units allocated to the API task."
  type        = number
  default     = 512
}

variable "api_memory" {
  description = "MiB of memory allocated to the API task."
  type        = number
  default     = 1024
}

variable "worker_cpu" {
  description = "Fargate CPU units allocated to the Worker task."
  type        = number
  default     = 512
}

variable "worker_memory" {
  description = "MiB of memory allocated to the Worker task."
  type        = number
  default     = 1024
}

variable "api_desired_count" {
  description = "Number of API tasks maintained by ECS."
  type        = number
  default     = 1

  validation {
    condition     = var.api_desired_count >= 0 && floor(var.api_desired_count) == var.api_desired_count
    error_message = "api_desired_count must be a non-negative integer."
  }
}

variable "worker_desired_count" {
  description = "Number of Worker tasks maintained by ECS."
  type        = number
  default     = 1

  validation {
    condition     = var.worker_desired_count >= 0 && floor(var.worker_desired_count) == var.worker_desired_count
    error_message = "worker_desired_count must be a non-negative integer."
  }
}

variable "cpu_architecture" {
  description = "Task CPU architecture; container images must match."
  type        = string
  default     = "X86_64"

  validation {
    condition     = contains(["X86_64", "ARM64"], var.cpu_architecture)
    error_message = "cpu_architecture must be X86_64 or ARM64."
  }
}

variable "fargate_platform_version" {
  description = "Fargate platform version supporting tmpfs and modern networking."
  type        = string
  default     = "1.4.0"

  validation {
    condition     = var.fargate_platform_version == "LATEST" || can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.fargate_platform_version))
    error_message = "fargate_platform_version must be LATEST or a semantic platform version."
  }
}

variable "health_check_grace_period_seconds" {
  description = "Startup grace period before ALB health failures affect deployment."
  type        = number
  default     = 60

  validation {
    condition     = var.health_check_grace_period_seconds >= 0 && var.health_check_grace_period_seconds <= 2147483647
    error_message = "health_check_grace_period_seconds must be non-negative."
  }
}

variable "api_deployment_controller" {
  description = "Deployment controller for the API service."
  type        = string
  default     = "ECS"

  validation {
    condition     = contains(["ECS", "CODE_DEPLOY"], var.api_deployment_controller)
    error_message = "api_deployment_controller must be ECS or CODE_DEPLOY."
  }
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for API and Worker streams."
  type        = number
  default     = 30

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days must be a CloudWatch-supported retention value."
  }
}

variable "log_level" {
  description = "Application log level injected into both containers."
  type        = string
  default     = "INFO"

  validation {
    condition     = contains(["DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"], var.log_level)
    error_message = "log_level must be a supported application log level."
  }
}

variable "otel_trace_sample_ratio" {
  description = "Head-sampling ratio used for new root traces; parent decisions are preserved."
  type        = number
  default     = 0.1

  validation {
    condition     = var.otel_trace_sample_ratio >= 0 && var.otel_trace_sample_ratio <= 1
    error_message = "otel_trace_sample_ratio must be between 0 and 1."
  }
}

variable "adot_collector_image" {
  description = "Version-pinned AWS-supported ADOT Collector sidecar image."
  type        = string
  default     = "public.ecr.aws/aws-observability/aws-otel-collector:v0.48.0"

  validation {
    condition     = can(regex("^public\\.ecr\\.aws/aws-observability/aws-otel-collector:v[0-9]+\\.[0-9]+\\.[0-9]+$", var.adot_collector_image))
    error_message = "adot_collector_image must use an explicit semantic-version tag from the AWS public repository."
  }
}

variable "job_max_receive_count" {
  description = "Receive attempts before the Worker marks a job failed and SQS redrives it."
  type        = number
  default     = 5

  validation {
    condition     = var.job_max_receive_count >= 1 && var.job_max_receive_count <= 1000
    error_message = "job_max_receive_count must be between 1 and 1000."
  }
}

variable "api_secrets" {
  description = "Map of environment variable names to Secrets Manager valueFrom ARNs."
  type        = map(string)
  default     = {}

  validation {
    condition = alltrue([
      for name, arn in var.api_secrets :
      can(regex("^[A-Za-z_][A-Za-z0-9_]*$", name)) && can(regex("^arn:[^:]+:secretsmanager:", arn))
    ])
    error_message = "api_secrets keys must be environment names and values must be Secrets Manager ARNs."
  }
}

variable "worker_secrets" {
  description = "Map of environment variable names to Worker secret valueFrom ARNs."
  type        = map(string)
  default     = {}

  validation {
    condition = alltrue([
      for name, arn in var.worker_secrets :
      can(regex("^[A-Za-z_][A-Za-z0-9_]*$", name)) && can(regex("^arn:[^:]+:secretsmanager:", arn))
    ])
    error_message = "worker_secrets keys must be environment names and values must be Secrets Manager ARNs."
  }
}

variable "tags" {
  description = "Additional resource tags."
  type        = map(string)
  default     = {}
}

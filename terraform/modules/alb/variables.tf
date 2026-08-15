variable "name" {
  description = "Short lowercase prefix used by ALB resources with strict name limits."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,17}[a-z0-9]$", var.name))
    error_message = "name must be 3-19 lowercase alphanumeric or hyphen characters."
  }
}

variable "vpc_id" {
  description = "VPC hosting the load balancer and target tasks."
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR used to restrict ALB egress to private targets."
  type        = string
}

variable "public_subnet_ids" {
  description = "At least two public subnets in distinct availability zones."
  type        = list(string)

  validation {
    condition     = length(distinct(var.public_subnet_ids)) >= 2
    error_message = "public_subnet_ids must contain at least two distinct subnets."
  }
}

variable "api_container_port" {
  description = "Port exposed by the API tasks."
  type        = number
  default     = 8000

  validation {
    condition     = var.api_container_port >= 1 && var.api_container_port <= 65535
    error_message = "api_container_port must be a valid TCP port."
  }
}

variable "health_check_path" {
  description = "API path used by target-group health checks."
  type        = string
  default     = "/health"

  validation {
    condition     = startswith(var.health_check_path, "/")
    error_message = "health_check_path must start with /."
  }
}

variable "certificate_arn" {
  description = "Optional ACM certificate ARN. Null enables HTTP-only development traffic."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.certificate_arn == null || can(regex("^arn:[^:]+:acm:[^:]+:[0-9]{12}:certificate/", var.certificate_arn))
    error_message = "certificate_arn must be null or a concrete ACM certificate ARN."
  }
}

variable "ssl_policy" {
  description = "TLS security policy for the optional HTTPS listener."
  type        = string
  default     = "ELBSecurityPolicy-TLS13-1-2-Res-2021-06"
}

variable "enable_deletion_protection" {
  description = "Protect the load balancer from accidental deletion."
  type        = bool
  default     = false
}

variable "enable_blue_green" {
  description = "Create the alternate API target group required by ECS CodeDeploy."
  type        = bool
  default     = false
}

variable "idle_timeout_seconds" {
  description = "ALB connection idle timeout."
  type        = number
  default     = 60

  validation {
    condition     = var.idle_timeout_seconds >= 1 && var.idle_timeout_seconds <= 4000
    error_message = "idle_timeout_seconds must be between 1 and 4000."
  }
}

variable "deregistration_delay_seconds" {
  description = "Connection draining delay during task replacement."
  type        = number
  default     = 30

  validation {
    condition     = var.deregistration_delay_seconds >= 0 && var.deregistration_delay_seconds <= 3600
    error_message = "deregistration_delay_seconds must be between 0 and 3600."
  }
}

variable "tags" {
  description = "Additional resource tags."
  type        = map(string)
  default     = {}
}

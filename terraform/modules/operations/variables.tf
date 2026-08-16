variable "name" {
  description = "Production workload name used to scope diagnostics."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$", var.name))
    error_message = "name must be 3-32 lowercase alphanumeric or hyphen characters."
  }
}

variable "github_oidc_provider_arn" {
  description = "Existing account GitHub Actions OIDC provider ARN."
  type        = string

  validation {
    condition     = can(regex("^arn:[^:]+:iam::[0-9]{12}:oidc-provider/token\\.actions\\.githubusercontent\\.com$", var.github_oidc_provider_arn))
    error_message = "github_oidc_provider_arn must be GitHub's account OIDC provider."
  }
}

variable "github_oidc_subjects" {
  description = "Exact protected production-operations environment subjects."
  type        = set(string)

  validation {
    condition = length(var.github_oidc_subjects) == 1 && alltrue([
      for subject in var.github_oidc_subjects : endswith(subject, ":environment:production-operations") && !strcontains(subject, "*")
    ])
    error_message = "Provide exactly one wildcard-free production-operations environment subject."
  }
}

variable "ecs_cluster_name" {
  description = "Exact ECS cluster inspected during incident diagnosis."
  type        = string

  validation {
    condition     = length(trimspace(var.ecs_cluster_name)) > 0 && !strcontains(var.ecs_cluster_name, "*")
    error_message = "ecs_cluster_name must be concrete."
  }
}

variable "ecs_service_names" {
  description = "Exact API and Worker ECS services inspected during diagnosis."
  type        = set(string)

  validation {
    condition     = length(var.ecs_service_names) == 2 && alltrue([for name in var.ecs_service_names : !strcontains(name, "*")])
    error_message = "ecs_service_names must contain two concrete service names."
  }
}

variable "queue_arns" {
  description = "Exact inference and dead-letter queue ARNs readable by diagnostics."
  type        = set(string)

  validation {
    condition     = length(var.queue_arns) == 2 && alltrue([for arn in var.queue_arns : can(regex("^arn:[^:]+:sqs:[^:]+:[0-9]{12}:[^*]+$", arn))])
    error_message = "queue_arns must contain two concrete SQS queue ARNs."
  }
}

variable "alarm_name_prefix" {
  description = "CloudWatch alarm prefix visible to incident diagnostics."
  type        = string

  validation {
    condition     = length(trimspace(var.alarm_name_prefix)) > 0 && !strcontains(var.alarm_name_prefix, "*")
    error_message = "alarm_name_prefix must be concrete."
  }
}

variable "cloudtrail_trail_name" {
  description = "Exact management trail whose delivery health is inspected."
  type        = string

  validation {
    condition     = length(trimspace(var.cloudtrail_trail_name)) > 0 && !strcontains(var.cloudtrail_trail_name, "*")
    error_message = "cloudtrail_trail_name must be concrete."
  }
}

variable "backup_vault_arn" {
  description = "Exact recovery vault inspected for backup health."
  type        = string

  validation {
    condition     = can(regex("^arn:[^:]+:backup:[^:]+:[0-9]{12}:backup-vault:[^*]+$", var.backup_vault_arn))
    error_message = "backup_vault_arn must be concrete."
  }
}

variable "codedeploy_deployment_group_arn" {
  description = "Exact deployment group inspected for release state."
  type        = string

  validation {
    condition     = can(regex("^arn:[^:]+:codedeploy:[^:]+:[0-9]{12}:deploymentgroup:[^*]+/[^*]+$", var.codedeploy_deployment_group_arn))
    error_message = "codedeploy_deployment_group_arn must be concrete."
  }
}

variable "tags" {
  description = "Tags applied to the operations role."
  type        = map(string)
  default     = {}
}

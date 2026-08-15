variable "name" {
  description = "Stable CodeDeploy application and group prefix."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$", var.name))
    error_message = "name must be 3-32 lowercase alphanumeric or hyphen characters."
  }
}

variable "ecs_cluster_name" {
  description = "ECS cluster containing the API service."
  type        = string
}

variable "ecs_service_name" {
  description = "API ECS service controlled by CodeDeploy."
  type        = string
}

variable "production_listener_arns" {
  description = "ALB production listeners shifted by CodeDeploy."
  type        = list(string)

  validation {
    condition = length(var.production_listener_arns) == 1 && alltrue([
      for arn in var.production_listener_arns : can(regex("^arn:[^:]+:elasticloadbalancing:[^:]+:[0-9]{12}:listener/", arn))
    ])
    error_message = "Exactly one concrete ALB production listener ARN is required."
  }
}

variable "target_group_names" {
  description = "Exactly two API target groups used as blue and green."
  type        = list(string)

  validation {
    condition     = length(var.target_group_names) == 2 && length(distinct(var.target_group_names)) == 2
    error_message = "target_group_names must contain two distinct target groups."
  }
}

variable "alarm_names" {
  description = "CloudWatch alarms that stop and roll back a deployment."
  type        = list(string)

  validation {
    condition     = length(var.alarm_names) > 0 && length(var.alarm_names) <= 10
    error_message = "CodeDeploy requires between one and ten deployment alarms."
  }
}

variable "deployment_config_name" {
  description = "CodeDeploy traffic-shifting policy."
  type        = string
  default     = "CodeDeployDefault.ECSCanary10Percent5Minutes"

  validation {
    condition     = startswith(var.deployment_config_name, "CodeDeployDefault.ECSCanary10Percent")
    error_message = "Production must begin with a 10 percent ECS canary."
  }
}

variable "blue_termination_wait_minutes" {
  description = "Bake time before the previous task set is terminated."
  type        = number
  default     = 10

  validation {
    condition     = var.blue_termination_wait_minutes >= 5 && var.blue_termination_wait_minutes <= 2880
    error_message = "blue_termination_wait_minutes must be between 5 and 2880."
  }
}

variable "tags" {
  description = "Additional resource tags."
  type        = map(string)
  default     = {}
}

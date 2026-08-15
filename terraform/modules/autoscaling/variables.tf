variable "name" {
  description = "Stable platform name used for scaling policy names and tags."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$", var.name))
    error_message = "name must be 3-32 lowercase alphanumeric or hyphen characters."
  }
}

variable "cluster_name" {
  description = "ECS cluster containing both scalable services."
  type        = string

  validation {
    condition     = length(trimspace(var.cluster_name)) > 0
    error_message = "cluster_name must not be empty."
  }
}

variable "api_service_name" {
  description = "ECS API service registered as a scalable target."
  type        = string

  validation {
    condition     = length(trimspace(var.api_service_name)) > 0
    error_message = "api_service_name must not be empty."
  }
}

variable "worker_service_name" {
  description = "ECS Worker service registered as a scalable target."
  type        = string

  validation {
    condition     = length(trimspace(var.worker_service_name)) > 0
    error_message = "worker_service_name must not be empty."
  }
}

variable "queue_name" {
  description = "SQS inference queue used to calculate backlog per Worker task."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_-]{1,80}$", var.queue_name))
    error_message = "queue_name must be a valid concrete SQS queue name."
  }
}

variable "api_min_capacity" {
  description = "Minimum API task count retained across scale-in events."
  type        = number

  validation {
    condition     = var.api_min_capacity >= 1 && floor(var.api_min_capacity) == var.api_min_capacity
    error_message = "api_min_capacity must be a positive integer."
  }
}

variable "api_max_capacity" {
  description = "Maximum API task count allowed during scale-out."
  type        = number

  validation {
    condition     = var.api_max_capacity >= 1 && floor(var.api_max_capacity) == var.api_max_capacity
    error_message = "api_max_capacity must be a positive integer."
  }
}

variable "worker_min_capacity" {
  description = "Minimum Worker task count retained across scale-in events."
  type        = number

  validation {
    condition     = var.worker_min_capacity >= 1 && floor(var.worker_min_capacity) == var.worker_min_capacity
    error_message = "worker_min_capacity must be a positive integer."
  }
}

variable "worker_max_capacity" {
  description = "Maximum Worker task count allowed during scale-out."
  type        = number

  validation {
    condition     = var.worker_max_capacity >= 1 && floor(var.worker_max_capacity) == var.worker_max_capacity
    error_message = "worker_max_capacity must be a positive integer."
  }
}

variable "api_cpu_target_percent" {
  description = "Average API CPU utilization maintained by target tracking."
  type        = number
  default     = 60

  validation {
    condition     = var.api_cpu_target_percent >= 20 && var.api_cpu_target_percent <= 90
    error_message = "api_cpu_target_percent must be between 20 and 90."
  }
}

variable "api_memory_target_percent" {
  description = "Average API memory utilization maintained by target tracking."
  type        = number
  default     = 70

  validation {
    condition     = var.api_memory_target_percent >= 20 && var.api_memory_target_percent <= 90
    error_message = "api_memory_target_percent must be between 20 and 90."
  }
}

variable "worker_backlog_target_per_task" {
  description = "Visible SQS jobs each running Worker should carry before scaling out."
  type        = number
  default     = 2

  validation {
    condition     = var.worker_backlog_target_per_task > 0 && var.worker_backlog_target_per_task <= 1000
    error_message = "worker_backlog_target_per_task must be greater than zero and at most 1000."
  }
}

variable "scale_out_cooldown_seconds" {
  description = "Delay after scale-out before another scale-out decision."
  type        = number
  default     = 60

  validation {
    condition     = var.scale_out_cooldown_seconds >= 0 && var.scale_out_cooldown_seconds <= 3600
    error_message = "scale_out_cooldown_seconds must be between 0 and 3600."
  }
}

variable "scale_in_cooldown_seconds" {
  description = "Conservative delay after scale-in before removing more capacity."
  type        = number
  default     = 300

  validation {
    condition     = var.scale_in_cooldown_seconds >= 0 && var.scale_in_cooldown_seconds <= 3600
    error_message = "scale_in_cooldown_seconds must be between 0 and 3600."
  }
}

variable "tags" {
  description = "Additional resource tags."
  type        = map(string)
  default     = {}
}

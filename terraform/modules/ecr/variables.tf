variable "name" {
  description = "ECR repository name."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]+(?:[._/-][a-z0-9]+)*$", var.name))
    error_message = "name must be a valid lowercase ECR repository name."
  }
}

variable "image_tag_mutability" {
  description = "Whether tags can be overwritten. Production defaults to immutable."
  type        = string
  default     = "IMMUTABLE"

  validation {
    condition     = contains(["MUTABLE", "IMMUTABLE"], var.image_tag_mutability)
    error_message = "image_tag_mutability must be MUTABLE or IMMUTABLE."
  }
}

variable "scan_on_push" {
  description = "Enable basic vulnerability scanning when images are pushed."
  type        = bool
  default     = true
}

variable "kms_key_arn" {
  description = "Optional customer-managed KMS key ARN; AES256 is used when null."
  type        = string
  default     = null
  nullable    = true
}

variable "untagged_image_retention_days" {
  description = "Age after which untagged images expire."
  type        = number
  default     = 7

  validation {
    condition     = var.untagged_image_retention_days >= 1
    error_message = "untagged_image_retention_days must be positive."
  }
}

variable "max_image_count" {
  description = "Maximum number of images retained in the repository."
  type        = number
  default     = 30

  validation {
    condition     = var.max_image_count >= 1
    error_message = "max_image_count must be positive."
  }
}

variable "force_delete" {
  description = "Allow deletion with images present; keep false outside ephemeral tests."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Additional resource tags."
  type        = map(string)
  default     = {}
}

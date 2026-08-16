variable "name" {
  description = "Stable production resource prefix."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,40}[a-z0-9]$", var.name))
    error_message = "name must be 3-42 lowercase alphanumeric or hyphen characters."
  }
}

variable "github_oidc_provider_arn" {
  description = "Existing account GitHub Actions OIDC provider."
  type        = string

  validation {
    condition     = can(regex("^arn:[^:]+:iam::[0-9]{12}:oidc-provider/token\\.actions\\.githubusercontent\\.com$", var.github_oidc_provider_arn))
    error_message = "github_oidc_provider_arn must be the account GitHub Actions provider."
  }
}

variable "github_oidc_subjects" {
  description = "Exact protected GitHub environment subjects allowed to audit drift."
  type        = set(string)

  validation {
    condition = length(var.github_oidc_subjects) == 1 && alltrue([
      for subject in var.github_oidc_subjects : endswith(subject, ":environment:production-drift") && !strcontains(subject, "*")
    ])
    error_message = "Drift detection requires one exact environment:production-drift subject."
  }
}

variable "terraform_state_bucket_arn" {
  description = "Exact S3 bucket ARN containing the production Terraform state."
  type        = string

  validation {
    condition     = can(regex("^arn:[^:]+:s3:::[^*]+$", var.terraform_state_bucket_arn))
    error_message = "terraform_state_bucket_arn must be one concrete S3 bucket ARN."
  }
}

variable "terraform_state_key" {
  description = "Exact production state object key."
  type        = string

  validation {
    condition     = length(trimspace(var.terraform_state_key)) > 0 && !startswith(var.terraform_state_key, "/") && !strcontains(var.terraform_state_key, "..") && !strcontains(var.terraform_state_key, "*")
    error_message = "terraform_state_key must be a concrete relative S3 object key."
  }
}

variable "terraform_state_kms_key_arn" {
  description = "Optional KMS key encrypting the production Terraform state."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.terraform_state_kms_key_arn == null || can(regex("^arn:[^:]+:kms:[^:]+:[0-9]{12}:key/[^*]+$", var.terraform_state_kms_key_arn))
    error_message = "terraform_state_kms_key_arn must be a concrete KMS key ARN."
  }
}

variable "managed_s3_bucket_arns" {
  description = "Application bucket ARNs whose configuration, but not objects, Terraform may refresh."
  type        = set(string)

  validation {
    condition = length(var.managed_s3_bucket_arns) > 0 && alltrue([
      for arn in var.managed_s3_bucket_arns : can(regex("^arn:[^:]+:s3:::[^*]+$", arn)) && arn != var.terraform_state_bucket_arn
    ])
    error_message = "managed_s3_bucket_arns must contain concrete non-state bucket ARNs."
  }
}

variable "metrics_namespace" {
  description = "CloudWatch namespace receiving the binary drift signal."
  type        = string
  default     = "CloudNativeLLMOps"

  validation {
    condition     = var.metrics_namespace == "CloudNativeLLMOps"
    error_message = "Drift metrics must remain in CloudNativeLLMOps."
  }
}

variable "tags" {
  description = "Additional resource tags."
  type        = map(string)
  default     = {}
}

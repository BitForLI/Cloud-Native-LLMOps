variable "name" {
  description = "Stable lowercase prefix for IAM role names and resource patterns."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$", var.name))
    error_message = "name must be 3-32 lowercase alphanumeric or hyphen characters."
  }
}

variable "api_ecr_repository_arn" {
  description = "ARN of the API image repository."
  type        = string

  validation {
    condition     = can(regex("^arn:[^:]+:ecr:[^:]+:[0-9]{12}:repository/.+$", var.api_ecr_repository_arn)) && !strcontains(var.api_ecr_repository_arn, "*")
    error_message = "api_ecr_repository_arn must be a concrete ECR repository ARN."
  }
}

variable "worker_ecr_repository_arn" {
  description = "ARN of the Worker image repository."
  type        = string

  validation {
    condition     = can(regex("^arn:[^:]+:ecr:[^:]+:[0-9]{12}:repository/.+$", var.worker_ecr_repository_arn)) && !strcontains(var.worker_ecr_repository_arn, "*")
    error_message = "worker_ecr_repository_arn must be a concrete ECR repository ARN."
  }
}

variable "promotion_source_ecr_repository_arns" {
  description = "Optional source repositories from which an environment may promote immutable images."
  type        = set(string)
  default     = []

  validation {
    condition = alltrue([
      for arn in var.promotion_source_ecr_repository_arns :
      can(regex("^arn:[^:]+:ecr:[^:]+:[0-9]{12}:repository/.+$", arn)) && !strcontains(arn, "*")
    ])
    error_message = "promotion_source_ecr_repository_arns must contain concrete ECR repository ARNs."
  }
}

variable "promotion_only" {
  description = "Restrict destination ECR writes to manifests whose layers already exist in the account registry."
  type        = bool
  default     = false
}

variable "github_api_update_enabled" {
  description = "Allow GitHub to update the API ECS service directly; disable when CodeDeploy owns API releases."
  type        = bool
  default     = true
}

variable "artifact_bucket_arn" {
  description = "ARN of the S3 artifact bucket."
  type        = string

  validation {
    condition     = can(regex("^arn:[^:]+:s3:::[^*]+$", var.artifact_bucket_arn))
    error_message = "artifact_bucket_arn must be a concrete S3 bucket ARN."
  }
}

variable "job_table_arn" {
  description = "ARN of the DynamoDB job table."
  type        = string

  validation {
    condition     = can(regex("^arn:[^:]+:dynamodb:[^:]+:[0-9]{12}:table/[^*]+$", var.job_table_arn))
    error_message = "job_table_arn must be a concrete DynamoDB table ARN."
  }
}

variable "inference_queue_arn" {
  description = "ARN of the SQS inference queue."
  type        = string

  validation {
    condition     = can(regex("^arn:[^:]+:sqs:[^:]+:[0-9]{12}:[^*]+$", var.inference_queue_arn))
    error_message = "inference_queue_arn must be a concrete SQS queue ARN."
  }
}

variable "bedrock_model_ids" {
  description = "Exact Bedrock foundation model IDs runtime tasks may invoke."
  type        = set(string)

  validation {
    condition     = length(var.bedrock_model_ids) > 0 && alltrue([for id in var.bedrock_model_ids : length(trimspace(id)) > 0 && !strcontains(id, "*")])
    error_message = "bedrock_model_ids must contain concrete non-empty model IDs without wildcards."
  }
}

variable "secret_arns" {
  description = "Optional Secrets Manager ARNs injected by ECS at startup."
  type        = set(string)
  default     = []

  validation {
    condition     = alltrue([for arn in var.secret_arns : can(regex("^arn:[^:]+:secretsmanager:", arn)) && !strcontains(arn, "*")])
    error_message = "secret_arns must contain concrete Secrets Manager ARNs."
  }
}

variable "kms_key_arns" {
  description = "Optional KMS keys required directly by application runtime data operations."
  type        = set(string)
  default     = []

  validation {
    condition     = alltrue([for arn in var.kms_key_arns : can(regex("^arn:[^:]+:kms:", arn)) && !strcontains(arn, "*")])
    error_message = "kms_key_arns must contain concrete KMS key ARNs."
  }
}

variable "secret_kms_key_arns" {
  description = "KMS keys used only by the ECS execution role to decrypt injected secrets."
  type        = set(string)
  default     = []

  validation {
    condition     = alltrue([for arn in var.secret_kms_key_arns : can(regex("^arn:[^:]+:kms:", arn)) && !strcontains(arn, "*")])
    error_message = "secret_kms_key_arns must contain concrete KMS key ARNs."
  }
}

variable "github_verification_secret_arns" {
  description = "Secrets the deployment role may read only for authenticated release verification."
  type        = set(string)
  default     = []

  validation {
    condition     = alltrue([for arn in var.github_verification_secret_arns : can(regex("^arn:[^:]+:secretsmanager:", arn)) && !strcontains(arn, "*")])
    error_message = "github_verification_secret_arns must contain concrete Secrets Manager ARNs."
  }
}

variable "github_verification_kms_key_arns" {
  description = "KMS keys the deployment role may use to decrypt release-verification secrets."
  type        = set(string)
  default     = []

  validation {
    condition     = alltrue([for arn in var.github_verification_kms_key_arns : can(regex("^arn:[^:]+:kms:", arn)) && !strcontains(arn, "*")])
    error_message = "github_verification_kms_key_arns must contain concrete KMS key ARNs."
  }
}

variable "github_oidc_provider_arn" {
  description = "Existing GitHub OIDC provider ARN; null creates the account-level provider."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.github_oidc_provider_arn == null || can(regex("^arn:[^:]+:iam::[0-9]{12}:oidc-provider/token\\.actions\\.githubusercontent\\.com$", var.github_oidc_provider_arn))
    error_message = "github_oidc_provider_arn must be the account GitHub Actions provider ARN."
  }
}

variable "github_oidc_subjects" {
  description = "Exact GitHub OIDC subject claims allowed to deploy."
  type        = set(string)

  validation {
    condition     = length(var.github_oidc_subjects) > 0 && alltrue([for subject in var.github_oidc_subjects : startswith(subject, "repo:") && !strcontains(subject, "*")])
    error_message = "github_oidc_subjects must contain exact repo: subjects without wildcards."
  }
}

variable "tags" {
  description = "Additional resource tags."
  type        = map(string)
  default     = {}
}

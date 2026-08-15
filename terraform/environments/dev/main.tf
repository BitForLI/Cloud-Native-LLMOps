locals {
  name = "${var.project_name}-${var.environment}"
  common_tags = {
    Environment = var.environment
    ManagedBy   = "terraform"
    Project     = var.project_name
  }
}

module "networking" {
  source = "../../modules/networking"

  name                    = local.name
  vpc_cidr                = var.vpc_cidr
  availability_zone_count = var.availability_zone_count
  availability_zones      = var.availability_zones
  nat_gateway_mode        = var.nat_gateway_mode
  tags                    = local.common_tags
}

module "api_ecr" {
  source = "../../modules/ecr"

  name = "${var.project_name}/${var.environment}/api"
  tags = local.common_tags
}

module "worker_ecr" {
  source = "../../modules/ecr"

  name = "${var.project_name}/${var.environment}/worker"
  tags = local.common_tags
}

module "database" {
  source = "../../modules/database"

  name                                    = local.name
  artifact_expiration_days                = 90
  dynamodb_deletion_protection_enabled    = false
  dynamodb_point_in_time_recovery_enabled = true
  force_destroy_artifacts                 = false
  tags                                    = local.common_tags
}

module "queue" {
  source = "../../modules/queue"

  name                       = local.name
  visibility_timeout_seconds = var.job_visibility_timeout_seconds
  max_receive_count          = var.job_max_receive_count
  tags                       = local.common_tags
}

module "iam" {
  source = "../../modules/iam"

  name                      = local.name
  api_ecr_repository_arn    = module.api_ecr.repository_arn
  worker_ecr_repository_arn = module.worker_ecr.repository_arn
  artifact_bucket_arn       = module.database.artifact_bucket_arn
  job_table_arn             = module.database.job_table_arn
  inference_queue_arn       = module.queue.queue_arn
  bedrock_model_ids         = [var.bedrock_model_id]
  github_oidc_provider_arn  = var.github_oidc_provider_arn
  github_oidc_subjects      = var.github_oidc_subjects
  tags                      = local.common_tags
}

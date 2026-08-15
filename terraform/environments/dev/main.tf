locals {
  name     = "${var.project_name}-${var.environment}"
  alb_name = "llmops-${var.environment}"
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

module "secrets" {
  source = "../../modules/secrets"

  name                        = local.name
  kms_deletion_window_days    = 14
  secret_recovery_window_days = 14
  tags                        = local.common_tags
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
  secret_arns               = [module.secrets.api_auth_secret_arn]
  secret_kms_key_arns       = [module.secrets.kms_key_arn]
  github_oidc_provider_arn  = var.github_oidc_provider_arn
  github_oidc_subjects      = var.github_oidc_subjects
  tags                      = local.common_tags
}

module "alb" {
  source = "../../modules/alb"

  name                       = local.alb_name
  vpc_id                     = module.networking.vpc_id
  vpc_cidr                   = module.networking.vpc_cidr
  public_subnet_ids          = module.networking.public_subnet_ids
  certificate_arn            = var.alb_certificate_arn
  enable_deletion_protection = false
  tags                       = local.common_tags
}

module "ecs" {
  source = "../../modules/ecs"

  name                  = local.name
  environment           = var.environment
  aws_region            = var.aws_region
  vpc_id                = module.networking.vpc_id
  private_subnet_ids    = module.networking.private_subnet_ids
  alb_security_group_id = module.alb.security_group_id
  api_target_group_arn  = module.alb.api_target_group_arn
  api_repository_url    = module.api_ecr.repository_url
  worker_repository_url = module.worker_ecr.repository_url
  api_image_tag         = var.api_image_tag
  worker_image_tag      = var.worker_image_tag
  execution_role_arn    = module.iam.execution_role_arn
  api_task_role_arn     = module.iam.api_task_role_arn
  worker_task_role_arn  = module.iam.worker_task_role_arn
  api_secrets = {
    API_AUTH_TOKEN = module.secrets.api_auth_secret_arn
  }
  bedrock_model_id        = var.bedrock_model_id
  artifact_bucket_name    = module.database.artifact_bucket_name
  job_table_name          = module.database.job_table_name
  inference_queue_url     = module.queue.queue_url
  job_max_receive_count   = var.job_max_receive_count
  api_desired_count       = var.api_desired_count
  worker_desired_count    = var.worker_desired_count
  log_retention_days      = var.log_retention_days
  otel_trace_sample_ratio = var.otel_trace_sample_ratio
  tags                    = local.common_tags

  depends_on = [
    module.networking,
    module.alb,
    module.iam,
    module.database,
    module.queue,
    module.secrets,
  ]
}

module "monitoring" {
  source = "../../modules/monitoring"

  name                                   = local.name
  environment                            = var.environment
  aws_region                             = var.aws_region
  cluster_name                           = module.ecs.cluster_name
  api_service_name                       = module.ecs.api_service_name
  worker_service_name                    = module.ecs.worker_service_name
  load_balancer_arn_suffix               = module.alb.load_balancer_arn_suffix
  target_group_arn_suffix                = module.alb.api_target_group_arn_suffix
  queue_name                             = module.queue.queue_name
  dead_letter_queue_name                 = module.queue.dead_letter_queue_name
  api_log_group_name                     = module.ecs.api_log_group_name
  worker_log_group_name                  = module.ecs.worker_log_group_name
  bedrock_model_id                       = var.bedrock_model_id
  notification_emails                    = var.alarm_notification_emails
  error_rate_threshold_percent           = var.alarm_error_rate_threshold_percent
  p95_latency_threshold_ms               = var.alarm_p95_latency_threshold_ms
  queue_age_threshold_seconds            = var.alarm_queue_age_threshold_seconds
  resource_utilization_threshold_percent = var.alarm_resource_utilization_threshold_percent
  tags                                   = local.common_tags
}

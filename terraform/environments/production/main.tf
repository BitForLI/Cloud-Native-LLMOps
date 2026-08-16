locals {
  name     = "${var.project_name}-prod"
  alb_name = "llmops-${var.environment}"
  common_tags = {
    Environment = var.environment
    ManagedBy   = "terraform"
    Project     = var.project_name
  }
}

module "networking" {
  source                  = "../../modules/networking"
  name                    = local.name
  vpc_cidr                = var.vpc_cidr
  availability_zone_count = var.availability_zone_count
  availability_zones      = var.availability_zones
  nat_gateway_mode        = "per_az"
  tags                    = local.common_tags
}

module "api_ecr" {
  source = "../../modules/ecr"
  name   = "${var.project_name}/${var.environment}/api"
  tags   = local.common_tags
}

module "worker_ecr" {
  source = "../../modules/ecr"
  name   = "${var.project_name}/${var.environment}/worker"
  tags   = local.common_tags
}

module "database" {
  source = "../../modules/database"

  name                                    = local.name
  artifact_expiration_days                = null
  noncurrent_version_retention_days       = 365
  dynamodb_deletion_protection_enabled    = true
  dynamodb_point_in_time_recovery_enabled = true
  force_destroy_artifacts                 = false
  tags                                    = local.common_tags
}

module "backup" {
  source = "../../modules/backup"

  name                    = local.name
  artifact_bucket_arn     = module.database.artifact_bucket_arn
  job_table_arn           = module.database.job_table_arn
  daily_retention_days    = var.backup_daily_retention_days
  weekly_retention_days   = var.backup_weekly_retention_days
  restore_testing_enabled = var.backup_restore_testing_enabled
  tags                    = local.common_tags

  depends_on = [module.database]
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
  kms_deletion_window_days    = 30
  secret_recovery_window_days = 30
  tags                        = local.common_tags
}

module "iam" {
  source = "../../modules/iam"

  name                                 = local.name
  api_ecr_repository_arn               = module.api_ecr.repository_arn
  worker_ecr_repository_arn            = module.worker_ecr.repository_arn
  promotion_source_ecr_repository_arns = var.promotion_source_ecr_repository_arns
  promotion_only                       = true
  github_api_update_enabled            = false
  artifact_bucket_arn                  = module.database.artifact_bucket_arn
  job_table_arn                        = module.database.job_table_arn
  inference_queue_arn                  = module.queue.queue_arn
  bedrock_model_ids                    = [var.bedrock_model_id]
  secret_arns                          = [module.secrets.api_auth_secret_arn]
  secret_kms_key_arns                  = [module.secrets.kms_key_arn]
  github_verification_secret_arns      = [module.secrets.api_auth_secret_arn]
  github_verification_kms_key_arns     = [module.secrets.kms_key_arn]
  github_oidc_provider_arn             = var.github_oidc_provider_arn
  github_oidc_subjects                 = var.github_oidc_subjects
  github_evaluation_oidc_subjects      = var.github_evaluation_oidc_subjects
  tags                                 = local.common_tags
}

module "alb" {
  source = "../../modules/alb"

  name                       = local.alb_name
  vpc_id                     = module.networking.vpc_id
  vpc_cidr                   = module.networking.vpc_cidr
  public_subnet_ids          = module.networking.public_subnet_ids
  certificate_arn            = var.alb_certificate_arn
  enable_deletion_protection = true
  enable_blue_green          = true
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
  bedrock_model_id          = var.bedrock_model_id
  artifact_bucket_name      = module.database.artifact_bucket_name
  job_table_name            = module.database.job_table_name
  inference_queue_url       = module.queue.queue_url
  job_max_receive_count     = var.job_max_receive_count
  api_desired_count         = var.api_desired_count
  worker_desired_count      = var.worker_desired_count
  log_retention_days        = var.log_retention_days
  otel_trace_sample_ratio   = var.otel_trace_sample_ratio
  api_deployment_controller = "CODE_DEPLOY"
  tags                      = local.common_tags

  depends_on = [module.networking, module.alb, module.iam, module.database, module.queue, module.secrets]
}

module "autoscaling" {
  source = "../../modules/autoscaling"

  name                           = local.name
  cluster_name                   = module.ecs.cluster_name
  api_service_name               = module.ecs.api_service_name
  worker_service_name            = module.ecs.worker_service_name
  queue_name                     = module.queue.queue_name
  api_min_capacity               = var.api_desired_count
  api_max_capacity               = var.api_max_capacity
  worker_min_capacity            = var.worker_desired_count
  worker_max_capacity            = var.worker_max_capacity
  worker_backlog_target_per_task = var.worker_backlog_target_per_task
  tags                           = local.common_tags

  depends_on = [module.ecs]
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
  alternate_target_group_arn_suffix      = module.alb.api_alternate_target_group_arn_suffix
  monitor_alternate_target_group         = true
  waf_enabled                            = true
  waf_web_acl_metric_name                = "${replace(local.name, "-", "")}WebAcl"
  evaluation_monitoring_enabled          = true
  evaluation_accuracy_threshold          = 0.90
  budget_notifications_enabled           = true
  llm_hourly_cost_threshold_usd          = var.alarm_llm_hourly_cost_threshold_usd
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

module "audit" {
  source = "../../modules/audit"

  name                   = local.name
  aws_region             = var.aws_region
  log_retention_days     = var.log_retention_days
  archive_retention_days = var.audit_archive_retention_days
  alarm_topic_arn        = module.monitoring.alarm_topic_arn
  tags                   = local.common_tags
}

module "cost_control" {
  source = "../../modules/cost_control"

  name                     = local.name
  monthly_budget_limit_usd = var.monthly_budget_limit_usd
  notification_topic_arn   = module.monitoring.alarm_topic_arn
  tags                     = local.common_tags

  depends_on = [module.monitoring]
}

module "waf" {
  source = "../../modules/waf"

  name                            = local.name
  aws_region                      = var.aws_region
  alb_arn                         = module.alb.load_balancer_arn
  rate_limit_per_five_minutes     = var.waf_rate_limit_per_five_minutes
  blocked_request_alarm_threshold = var.waf_blocked_request_alarm_threshold
  alarm_topic_arn                 = module.monitoring.alarm_topic_arn
  log_retention_days              = var.log_retention_days
  tags                            = local.common_tags
}

module "codedeploy" {
  source = "../../modules/codedeploy"

  name                     = local.name
  ecs_cluster_name         = module.ecs.cluster_name
  ecs_service_name         = module.ecs.api_service_name
  production_listener_arns = [module.alb.api_listener_arn]
  target_group_names = [
    module.alb.api_target_group_name,
    module.alb.api_alternate_target_group_name,
  ]
  alarm_names                   = module.monitoring.deployment_alarm_names.api
  deployment_config_name        = "CodeDeployDefault.ECSCanary10Percent5Minutes"
  blue_termination_wait_minutes = var.blue_termination_wait_minutes
  tags                          = local.common_tags
}

resource "aws_iam_role_policy" "production_codedeploy" {
  name = "${local.name}-codedeploy-release"
  role = module.iam.github_deploy_role_name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "ReleaseOnlyThroughCodeDeploy"
      Effect = "Allow"
      Action = [
        "codedeploy:CreateDeployment",
        "codedeploy:GetDeployment",
        "codedeploy:StopDeployment",
      ]
      Resource = [module.codedeploy.deployment_group_arn]
    }]
  })
}

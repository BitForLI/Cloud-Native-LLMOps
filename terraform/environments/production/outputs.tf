output "vpc_id" {
  description = "Production VPC ID."
  value       = module.networking.vpc_id
}

output "nat_gateway_ids" {
  description = "Production NAT gateways keyed by availability zone."
  value       = module.networking.nat_gateway_ids
}

output "api_url" {
  description = "Public production HTTPS origin."
  value       = "https://${module.alb.load_balancer_dns_name}"
}

output "cloudwatch_dashboard_name" {
  description = "Production operations dashboard."
  value       = module.monitoring.dashboard_name
}

output "api_auth_secret_name" {
  description = "Secrets Manager container populated outside Terraform for API authentication."
  value       = module.secrets.api_auth_secret_name
}

output "deployment_alarm_names" {
  description = "Alarm sets protecting production releases."
  value       = module.monitoring.deployment_alarm_names
}

output "production_safety_profile" {
  description = "Auditable production resilience and release settings."
  value = {
    availability_zone_count    = length(module.networking.availability_zones)
    nat_gateway_count          = length(module.networking.nat_gateway_ids)
    api_desired_count          = var.api_desired_count
    worker_desired_count       = var.worker_desired_count
    log_retention_days         = var.log_retention_days
    data_deletion_protection   = module.database.job_table_deletion_protection_enabled
    load_balancer_protection   = module.alb.deletion_protection_enabled
    api_alternate_target_group = module.alb.blue_green_enabled
    deployment_config          = "CodeDeployDefault.ECSCanary10Percent5Minutes"
    blue_termination_wait      = var.blue_termination_wait_minutes
    encrypted_api_auth         = module.secrets.kms_key_rotation_enabled
    trace_sample_ratio         = module.ecs.otel_trace_sample_ratio
    adot_collector_image       = module.ecs.adot_collector_image
    autoscaling_bounds         = module.autoscaling.capacity_bounds
    worker_backlog_target      = module.autoscaling.worker_backlog_target_per_task
    waf_enabled                = module.waf.enabled
    waf_web_acl_arn            = module.waf.web_acl_arn
    waf_log_group              = module.waf.log_group_name
    waf_rate_limit             = module.waf.rate_limit_per_five_minutes
    waf_alarm_name             = module.waf.blocked_request_alarm_name
    evaluation_alarm_names     = module.monitoring.evaluation_alarm_names
    llm_hourly_cost_alarm      = module.monitoring.llm_cost_alarm_name
    monthly_budget_name        = module.cost_control.budget_name
    monthly_budget_limit_usd   = module.cost_control.monthly_budget_limit_usd
    budget_alert_thresholds    = module.cost_control.notification_thresholds
    audit_trail_name           = module.audit.trail_name
    audit_archive_bucket       = module.audit.archive_bucket_name
    audit_log_group            = module.audit.log_group_name
    audit_validation_enabled   = module.audit.log_file_validation_enabled
    security_alarm_names       = module.audit.security_alarm_names
    backup_vault_name          = module.backup.vault_name
    backup_plan_name           = module.backup.plan_name
    backup_retention_days      = module.backup.retention_days
    protected_resource_arns    = module.backup.protected_resource_arns
    restore_testing_plan_name  = module.backup.restore_testing_plan_name
  }
}

output "deployment_github_variables" {
  description = "GitHub production-environment variables for protected release automation."
  value = {
    AWS_ACCOUNT_ID                   = split(":", module.iam.github_deploy_role_arn)[4]
    AWS_DEPLOY_ROLE_ARN              = module.iam.github_deploy_role_arn
    AWS_EVALUATION_ROLE_ARN          = module.iam.github_evaluation_role_arn
    AWS_REGION                       = var.aws_region
    PRODUCTION_API_ECR_REPOSITORY    = module.api_ecr.repository_name
    PRODUCTION_WORKER_ECR_REPOSITORY = module.worker_ecr.repository_name
    ECS_CLUSTER                      = module.ecs.cluster_name
    API_ECS_SERVICE                  = module.ecs.api_service_name
    WORKER_ECS_SERVICE               = module.ecs.worker_service_name
    API_URL                          = "https://${module.alb.load_balancer_dns_name}"
    CODEDEPLOY_APPLICATION           = module.codedeploy.application_name
    CODEDEPLOY_DEPLOYMENT_GROUP      = module.codedeploy.deployment_group_name
    API_AUTH_SECRET_ID               = module.secrets.api_auth_secret_name
    ARTIFACT_BUCKET                  = module.database.artifact_bucket_name
  }
}

output "operations_github_variables" {
  description = "Non-secret variables for the protected production-operations diagnostics workflow."
  value = {
    AWS_ACCOUNT_ID              = split(":", module.operations.role_arn)[4]
    AWS_OPERATIONS_ROLE_ARN     = module.operations.role_arn
    AWS_REGION                  = var.aws_region
    ECS_CLUSTER                 = module.ecs.cluster_name
    API_ECS_SERVICE             = module.ecs.api_service_name
    WORKER_ECS_SERVICE          = module.ecs.worker_service_name
    INFERENCE_QUEUE_URL         = module.queue.queue_url
    DEAD_LETTER_QUEUE_URL       = module.queue.dead_letter_queue_url
    ALARM_NAME_PREFIX           = local.name
    AUDIT_TRAIL_NAME            = module.audit.trail_name
    BACKUP_VAULT_NAME           = module.backup.vault_name
    RESTORE_TESTING_PLAN_ARN    = module.backup.restore_testing_plan_arn
    CODEDEPLOY_APPLICATION      = module.codedeploy.application_name
    CODEDEPLOY_DEPLOYMENT_GROUP = module.codedeploy.deployment_group_name
  }
}

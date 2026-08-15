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
  }
}

output "deployment_github_variables" {
  description = "GitHub production-environment variables for protected release automation."
  value = {
    AWS_ACCOUNT_ID                   = split(":", module.iam.github_deploy_role_arn)[4]
    AWS_DEPLOY_ROLE_ARN              = module.iam.github_deploy_role_arn
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
  }
}

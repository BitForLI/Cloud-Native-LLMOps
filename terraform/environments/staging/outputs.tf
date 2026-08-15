output "vpc_id" {
  description = "Staging VPC ID."
  value       = module.networking.vpc_id
}

output "nat_gateway_ids" {
  description = "Per-AZ staging NAT gateway IDs."
  value       = module.networking.nat_gateway_ids
}

output "ecr_repository_urls" {
  description = "Staging image destinations."
  value = {
    api    = module.api_ecr.repository_url
    worker = module.worker_ecr.repository_url
  }
}

output "api_url" {
  description = "Public staging HTTPS origin."
  value       = "https://${module.alb.load_balancer_dns_name}"
}

output "github_deploy_role_arn" {
  description = "OIDC role used only by the staging GitHub environment."
  value       = module.iam.github_deploy_role_arn
}

output "cloudwatch_dashboard_name" {
  description = "Staging operations dashboard."
  value       = module.monitoring.dashboard_name
}

output "staging_safety_profile" {
  description = "Auditable production-like staging capacity and retention controls."
  value = {
    nat_gateway_mode         = var.nat_gateway_mode
    api_desired_count        = var.api_desired_count
    worker_desired_count     = var.worker_desired_count
    log_retention_days       = var.log_retention_days
    data_deletion_protection = module.database.job_table_deletion_protection_enabled
    load_balancer_protection = module.alb.deletion_protection_enabled
  }
}

output "deployment_github_variables" {
  description = "GitHub staging-environment variables for artifact promotion."
  value = {
    AWS_ACCOUNT_ID                = split(":", module.iam.github_deploy_role_arn)[4]
    AWS_DEPLOY_ROLE_ARN           = module.iam.github_deploy_role_arn
    AWS_REGION                    = var.aws_region
    STAGING_API_ECR_REPOSITORY    = module.api_ecr.repository_name
    STAGING_WORKER_ECR_REPOSITORY = module.worker_ecr.repository_name
    ECS_CLUSTER                   = module.ecs.cluster_name
    API_ECS_SERVICE               = module.ecs.api_service_name
    WORKER_ECS_SERVICE            = module.ecs.worker_service_name
    API_URL                       = "https://${module.alb.load_balancer_dns_name}"
  }
}

output "vpc_id" {
  description = "Development VPC ID."
  value       = module.networking.vpc_id
}

output "public_subnet_ids" {
  description = "Public subnets reserved for the ALB."
  value       = module.networking.public_subnet_ids
}

output "private_subnet_ids" {
  description = "Private subnets reserved for ECS tasks."
  value       = module.networking.private_subnet_ids
}

output "availability_zones" {
  description = "Availability zones used by the development network."
  value       = module.networking.availability_zones
}

output "nat_gateway_ids" {
  description = "NAT gateway IDs keyed by availability zone."
  value       = module.networking.nat_gateway_ids
}

output "ecr_repository_urls" {
  description = "Image destinations keyed by service."
  value = {
    api    = module.api_ecr.repository_url
    worker = module.worker_ecr.repository_url
  }
}

output "artifact_bucket_name" {
  description = "Private S3 bucket for evaluation and inference artifacts."
  value       = module.database.artifact_bucket_name
}

output "job_table_name" {
  description = "DynamoDB table used for durable job state."
  value       = module.database.job_table_name
}

output "inference_queue_url" {
  description = "SQS queue URL consumed by the API and Worker."
  value       = module.queue.queue_url
}

output "inference_dead_letter_queue_url" {
  description = "SQS DLQ URL used for failed-job inspection and redrive."
  value       = module.queue.dead_letter_queue_url
}

output "ecs_execution_role_arn" {
  description = "Role ECS uses for image pulls and container log delivery."
  value       = module.iam.execution_role_arn
}

output "api_task_role_arn" {
  description = "Least-privilege runtime role for the API."
  value       = module.iam.api_task_role_arn
}

output "worker_task_role_arn" {
  description = "Least-privilege runtime role for the Worker."
  value       = module.iam.worker_task_role_arn
}

output "github_deploy_role_arn" {
  description = "OIDC deployment role configured as a GitHub environment variable."
  value       = module.iam.github_deploy_role_arn
}

output "api_auth_secret_name" {
  description = "Secrets Manager container populated outside Terraform for API authentication."
  value       = module.secrets.api_auth_secret_name
}

output "api_url" {
  description = "Public API origin URL."
  value       = "${var.alb_certificate_arn == null ? "http" : "https"}://${module.alb.load_balancer_dns_name}"
}

output "ecs_cluster_name" {
  description = "ECS cluster targeted by deployment workflows."
  value       = module.ecs.cluster_name
}

output "ecs_service_names" {
  description = "ECS service names keyed by component."
  value = {
    api    = module.ecs.api_service_name
    worker = module.ecs.worker_service_name
  }
}

output "cloudwatch_log_groups" {
  description = "Container log groups keyed by component."
  value = {
    api    = module.ecs.api_log_group_name
    worker = module.ecs.worker_log_group_name
  }
}

output "cloudwatch_dashboard_name" {
  description = "Operations dashboard for API, Worker, queue, and LLM signals."
  value       = module.monitoring.dashboard_name
}

output "alarm_topic_arn" {
  description = "SNS topic receiving CloudWatch alarm state changes."
  value       = module.monitoring.alarm_topic_arn
}

output "cloudwatch_alarm_names" {
  description = "CloudWatch alarms protecting the development platform."
  value       = module.monitoring.alarm_names
}

output "deployment_github_variables" {
  description = "Repository variables required by the development deployment workflow."
  value = {
    AWS_ACCOUNT_ID        = split(":", module.iam.github_deploy_role_arn)[4]
    AWS_DEPLOY_ROLE_ARN   = module.iam.github_deploy_role_arn
    AWS_REGION            = var.aws_region
    API_ECR_REPOSITORY    = module.api_ecr.repository_name
    WORKER_ECR_REPOSITORY = module.worker_ecr.repository_name
    ECS_CLUSTER           = module.ecs.cluster_name
    API_ECS_SERVICE       = module.ecs.api_service_name
    WORKER_ECS_SERVICE    = module.ecs.worker_service_name
    API_URL               = "${var.alb_certificate_arn == null ? "http" : "https"}://${module.alb.load_balancer_dns_name}"
  }
}

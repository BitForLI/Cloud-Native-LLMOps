output "cluster_arn" {
  description = "ARN of the ECS cluster."
  value       = aws_ecs_cluster.this.arn
}

output "cluster_name" {
  description = "Name of the ECS cluster."
  value       = aws_ecs_cluster.this.name
}

output "api_service_name" {
  description = "API ECS service name consumed by deployments."
  value       = aws_ecs_service.api.name
}

output "worker_service_name" {
  description = "Worker ECS service name consumed by deployments."
  value       = aws_ecs_service.worker.name
}

output "api_task_definition_arn" {
  description = "Current API task definition ARN."
  value       = aws_ecs_task_definition.api.arn
}

output "worker_task_definition_arn" {
  description = "Current Worker task definition ARN."
  value       = aws_ecs_task_definition.worker.arn
}

output "task_security_group_id" {
  description = "Security group attached to both private ECS services."
  value       = aws_security_group.tasks.id
}

output "api_log_group_name" {
  description = "CloudWatch log group for API container logs."
  value       = aws_cloudwatch_log_group.api.name
}

output "worker_log_group_name" {
  description = "CloudWatch log group for Worker container logs."
  value       = aws_cloudwatch_log_group.worker.name
}

output "adot_collector_image" {
  description = "Version-pinned ADOT Collector image shared by API and Worker tasks."
  value       = var.adot_collector_image
}

output "otel_trace_sample_ratio" {
  description = "Configured root-trace sampling ratio."
  value       = var.otel_trace_sample_ratio
}

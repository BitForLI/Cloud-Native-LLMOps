output "capacity_bounds" {
  description = "Minimum and maximum ECS task counts enforced by Application Auto Scaling."
  value = {
    api = {
      min = aws_appautoscaling_target.api.min_capacity
      max = aws_appautoscaling_target.api.max_capacity
    }
    worker = {
      min = aws_appautoscaling_target.worker.min_capacity
      max = aws_appautoscaling_target.worker.max_capacity
    }
  }
}

output "policy_arns" {
  description = "Target-tracking scaling policy ARNs keyed by signal."
  value = {
    api_cpu        = aws_appautoscaling_policy.api_cpu.arn
    api_memory     = aws_appautoscaling_policy.api_memory.arn
    worker_backlog = aws_appautoscaling_policy.worker_backlog.arn
  }
}

output "worker_backlog_target_per_task" {
  description = "Configured target number of visible jobs per running Worker."
  value       = var.worker_backlog_target_per_task
}

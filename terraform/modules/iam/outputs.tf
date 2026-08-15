output "execution_role_arn" {
  description = "ECS task execution role ARN."
  value       = aws_iam_role.execution.arn
  depends_on  = [aws_iam_role_policy.execution]
}

output "api_task_role_arn" {
  description = "Runtime role ARN for the API task."
  value       = aws_iam_role.api_task.arn
  depends_on  = [aws_iam_role_policy.api_task]
}

output "worker_task_role_arn" {
  description = "Runtime role ARN for the Worker task."
  value       = aws_iam_role.worker_task.arn
  depends_on  = [aws_iam_role_policy.worker_task]
}

output "github_deploy_role_arn" {
  description = "OIDC-assumable role ARN used by GitHub deployment jobs."
  value       = aws_iam_role.github_deploy.arn
  depends_on  = [aws_iam_role_policy.github_deploy]
}

output "github_oidc_provider_arn" {
  description = "Created or supplied GitHub OIDC provider ARN."
  value       = local.oidc_provider_arn
}

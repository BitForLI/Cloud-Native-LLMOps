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

output "github_deploy_role_name" {
  description = "Name used when attaching environment-specific deployment permissions."
  value       = aws_iam_role.github_deploy.name
}

output "github_evaluation_role_arn" {
  description = "Dedicated least-privilege role ARN used by continuous evaluation jobs."
  value       = try(aws_iam_role.github_evaluation[0].arn, null)
  depends_on  = [aws_iam_role_policy.github_evaluation]
}

output "github_oidc_provider_arn" {
  description = "Created or supplied GitHub OIDC provider ARN."
  value       = local.oidc_provider_arn
}

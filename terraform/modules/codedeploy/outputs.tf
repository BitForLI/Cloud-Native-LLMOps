output "application_name" {
  description = "CodeDeploy ECS application name."
  value       = aws_codedeploy_app.api.name
}

output "deployment_group_name" {
  description = "API blue/green deployment group name."
  value       = aws_codedeploy_deployment_group.api.deployment_group_name
}

output "deployment_group_arn" {
  description = "ARN used to scope release automation permissions."
  value       = aws_codedeploy_deployment_group.api.arn
}

output "service_role_arn" {
  description = "Role CodeDeploy uses to manage ECS and ALB resources."
  value       = aws_iam_role.codedeploy.arn
}

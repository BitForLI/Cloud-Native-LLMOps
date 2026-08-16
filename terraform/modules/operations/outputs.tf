output "role_arn" {
  description = "GitHub OIDC role limited to read-only production diagnostics."
  value       = aws_iam_role.github_operations.arn
}

output "role_name" {
  description = "Read-only production diagnostics role name."
  value       = aws_iam_role.github_operations.name
}

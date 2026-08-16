output "role_arn" {
  description = "OIDC role assumed by the production drift workflow."
  value       = aws_iam_role.github_drift.arn
}

output "role_name" {
  description = "Name of the production drift-audit role."
  value       = aws_iam_role.github_drift.name
}

output "state_bucket" {
  description = "Backend bucket name exposed as a non-secret workflow variable."
  value       = split(":::", var.terraform_state_bucket_arn)[1]
}

output "state_key" {
  description = "Exact backend state key exposed as a non-secret workflow variable."
  value       = var.terraform_state_key
}

output "audit_policy" {
  description = "Rendered policy used by Terraform tests to prove read-only boundaries."
  value       = local.audit_policy
}

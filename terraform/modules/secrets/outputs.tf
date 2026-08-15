output "api_auth_secret_arn" {
  description = "ARN injected into the API task as API_AUTH_TOKEN."
  value       = aws_secretsmanager_secret.api_auth_token.arn
}

output "api_auth_secret_name" {
  description = "Stable secret identifier used during bootstrap and release verification."
  value       = aws_secretsmanager_secret.api_auth_token.name
}

output "kms_key_arn" {
  description = "Customer-managed key encrypting application secrets."
  value       = aws_kms_key.secrets.arn
}

output "kms_key_rotation_enabled" {
  description = "Whether automatic annual KMS key-material rotation is enabled."
  value       = aws_kms_key.secrets.enable_key_rotation
}

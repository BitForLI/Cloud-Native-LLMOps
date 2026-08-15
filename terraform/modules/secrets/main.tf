locals {
  common_tags = merge(var.tags, { Component = "secrets" })
}

resource "aws_kms_key" "secrets" {
  description             = "Encrypt Secrets Manager values for ${var.name}"
  enable_key_rotation     = true
  deletion_window_in_days = var.kms_deletion_window_days
  tags                    = merge(local.common_tags, { Name = "${var.name}-secrets" })
}

resource "aws_kms_alias" "secrets" {
  name          = "alias/${var.name}-secrets"
  target_key_id = aws_kms_key.secrets.key_id
}

resource "aws_secretsmanager_secret" "api_auth_token" {
  name                    = "${var.name}/api-auth-token"
  description             = "Bearer value accepted in the X-API-Key header"
  kms_key_id              = aws_kms_key.secrets.arn
  recovery_window_in_days = var.secret_recovery_window_days
  tags                    = merge(local.common_tags, { Name = "${var.name}-api-auth-token" })
}

resource "aws_secretsmanager_secret_policy" "api_auth_token" {
  secret_arn          = aws_secretsmanager_secret.api_auth_token.arn
  block_public_policy = true
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "secretsmanager:*"
      Resource  = "*"
      Condition = {
        Bool = { "aws:SecureTransport" = "false" }
      }
    }]
  })
}

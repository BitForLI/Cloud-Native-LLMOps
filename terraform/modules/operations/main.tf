data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.region
  oidc_host  = "token.actions.githubusercontent.com"
  service_arns = sort([
    for service in var.ecs_service_names :
    "arn:${local.partition}:ecs:${local.region}:${local.account_id}:service/${var.ecs_cluster_name}/${service}"
  ])
  trail_arn = "arn:${local.partition}:cloudtrail:${local.region}:${local.account_id}:trail/${var.cloudtrail_trail_name}"
  alarm_arn = "arn:${local.partition}:cloudwatch:${local.region}:${local.account_id}:alarm:${var.alarm_name_prefix}*"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "GitHubProtectedOperationsEnvironment"
      Effect    = "Allow"
      Principal = { Federated = var.github_oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_host}:aud" = "sts.amazonaws.com"
          "${local.oidc_host}:sub" = sort(tolist(var.github_oidc_subjects))
        }
      }
    }]
  })

  diagnostics_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "DescribeWorkloadServices"
        Effect   = "Allow"
        Action   = ["ecs:DescribeServices"]
        Resource = local.service_arns
      },
      {
        Sid      = "ReadWorkloadAlarms"
        Effect   = "Allow"
        Action   = ["cloudwatch:DescribeAlarms"]
        Resource = [local.alarm_arn]
      },
      {
        Sid      = "ReadQueuePressure"
        Effect   = "Allow"
        Action   = ["sqs:GetQueueAttributes"]
        Resource = sort(tolist(var.queue_arns))
      },
      {
        Sid      = "ReadAuditDeliveryHealth"
        Effect   = "Allow"
        Action   = ["cloudtrail:GetTrailStatus"]
        Resource = [local.trail_arn]
      },
      {
        Sid      = "ReadRecoveryHealth"
        Effect   = "Allow"
        Action   = ["backup:DescribeBackupVault"]
        Resource = [var.backup_vault_arn]
      },
      {
        Sid      = "ListRecentRecoveryJobs"
        Effect   = "Allow"
        Action   = ["backup:ListBackupJobs", "backup:ListRestoreJobs"]
        Resource = ["*"]
      },
      {
        Sid      = "ReadDeploymentGroupHealth"
        Effect   = "Allow"
        Action   = ["codedeploy:GetDeploymentGroup"]
        Resource = [var.codedeploy_deployment_group_arn]
      },
      {
        Sid    = "DenyMutationAndSensitiveReads"
        Effect = "Deny"
        Action = [
          "backup:Delete*",
          "backup:Start*",
          "backup:Stop*",
          "codedeploy:CreateDeployment",
          "codedeploy:StopDeployment",
          "ecs:ExecuteCommand",
          "ecs:RegisterTaskDefinition",
          "ecs:UpdateService",
          "iam:PassRole",
          "secretsmanager:GetSecretValue",
          "sqs:DeleteMessage",
          "sqs:PurgeQueue",
          "sqs:SendMessage",
        ]
        Resource = ["*"]
      },
    ]
  })
}

resource "aws_iam_role" "github_operations" {
  name                 = "${var.name}-github-operations"
  assume_role_policy   = local.assume_role_policy
  max_session_duration = 3600
  tags                 = merge(var.tags, { Component = "operations" })
}

resource "aws_iam_role_policy" "github_operations" {
  name   = "${var.name}-read-only-diagnostics"
  role   = aws_iam_role.github_operations.id
  policy = local.diagnostics_policy
}

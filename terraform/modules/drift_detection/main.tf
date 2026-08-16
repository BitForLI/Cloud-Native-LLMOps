locals {
  state_object_arn = "${var.terraform_state_bucket_arn}/${var.terraform_state_key}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowProtectedDriftAudit"
      Effect    = "Allow"
      Action    = ["sts:AssumeRoleWithWebIdentity"]
      Principal = { Federated = [var.github_oidc_provider_arn] }
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = ["sts.amazonaws.com"]
          "token.actions.githubusercontent.com:sub" = sort(tolist(var.github_oidc_subjects))
        }
      }
    }]
  })

  infrastructure_read_actions = [
    "acm:DescribeCertificate",
    "acm:ListTagsForCertificate",
    "application-autoscaling:Describe*",
    "autoscaling:Describe*",
    "backup:Describe*",
    "backup:Get*",
    "backup:List*",
    "budgets:Describe*",
    "cloudtrail:Describe*",
    "cloudtrail:Get*",
    "cloudtrail:List*",
    "cloudwatch:Describe*",
    "cloudwatch:Get*",
    "cloudwatch:List*",
    "codedeploy:Get*",
    "codedeploy:List*",
    "dynamodb:Describe*",
    "dynamodb:List*",
    "ec2:Describe*",
    "ecr:Describe*",
    "ecr:GetLifecyclePolicy",
    "ecr:GetLifecyclePolicyPreview",
    "ecr:GetRegistryPolicy",
    "ecr:GetRegistryScanningConfiguration",
    "ecr:GetRepositoryPolicy",
    "ecr:List*",
    "ecs:Describe*",
    "ecs:List*",
    "elasticloadbalancing:Describe*",
    "iam:Get*",
    "iam:List*",
    "kms:Describe*",
    "kms:Get*",
    "kms:List*",
    "logs:Describe*",
    "logs:List*",
    "s3:ListAllMyBuckets",
    "secretsmanager:DescribeSecret",
    "secretsmanager:GetResourcePolicy",
    "secretsmanager:ListSecretVersionIds",
    "secretsmanager:ListTagsForResource",
    "sns:Get*",
    "sns:List*",
    "sqs:GetQueueAttributes",
    "sqs:ListQueueTags",
    "tag:GetResources",
    "wafv2:GetIPSet",
    "wafv2:GetLoggingConfiguration",
    "wafv2:GetManagedRuleSet",
    "wafv2:GetPermissionPolicy",
    "wafv2:GetRegexPatternSet",
    "wafv2:GetRuleGroup",
    "wafv2:GetWebACL",
    "wafv2:GetWebACLForResource",
    "wafv2:List*",
    "xray:Get*",
  ]

  audit_policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid      = "ReadExactTerraformStateBucket"
          Effect   = "Allow"
          Action   = ["s3:ListBucket"]
          Resource = [var.terraform_state_bucket_arn]
          Condition = {
            StringEquals = { "s3:prefix" = [var.terraform_state_key] }
          }
        },
        {
          Sid      = "ReadTerraformStateBucketLocation"
          Effect   = "Allow"
          Action   = ["s3:GetBucketLocation"]
          Resource = [var.terraform_state_bucket_arn]
        },
        {
          Sid      = "ReadExactTerraformStateObject"
          Effect   = "Allow"
          Action   = ["s3:GetObject"]
          Resource = [local.state_object_arn]
        },
        {
          Sid      = "ReadManagedInfrastructureConfiguration"
          Effect   = "Allow"
          Action   = local.infrastructure_read_actions
          Resource = ["*"]
        },
        {
          Sid    = "ReadManagedBucketConfiguration"
          Effect = "Allow"
          Action = [
            "s3:GetBucket*",
            "s3:GetEncryptionConfiguration",
            "s3:GetLifecycleConfiguration",
            "s3:ListBucket",
          ]
          Resource = sort(tolist(var.managed_s3_bucket_arns))
        },
        {
          Sid      = "PublishBinaryDriftSignal"
          Effect   = "Allow"
          Action   = ["cloudwatch:PutMetricData"]
          Resource = ["*"]
          Condition = {
            StringEquals = { "cloudwatch:namespace" = [var.metrics_namespace] }
          }
        },
        {
          Sid    = "DenySensitiveDataReads"
          Effect = "Deny"
          Action = [
            "dynamodb:BatchGetItem",
            "dynamodb:GetItem",
            "dynamodb:PartiQLSelect",
            "dynamodb:Query",
            "dynamodb:Scan",
            "secretsmanager:GetSecretValue",
            "ssm:GetParameter",
            "ssm:GetParameters",
            "ssm:GetParametersByPath",
          ]
          Resource = ["*"]
        },
      ],
      var.terraform_state_kms_key_arn == null ? [] : [{
        Sid      = "DecryptExactTerraformStateKey"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = [var.terraform_state_kms_key_arn]
      }],
    )
  })
}

resource "aws_iam_role" "github_drift" {
  name               = "${var.name}-github-drift"
  assume_role_policy = local.assume_role_policy
  tags               = merge(var.tags, { Role = "github-drift-audit" })
}

resource "aws_iam_role_policy" "github_drift" {
  name   = "${var.name}-read-only-drift"
  role   = aws_iam_role.github_drift.id
  policy = local.audit_policy
}

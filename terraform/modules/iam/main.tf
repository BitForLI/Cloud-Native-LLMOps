data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.region

  bedrock_model_arns = [
    for model_id in var.bedrock_model_ids :
    "arn:${local.partition}:bedrock:${local.region}::foundation-model/${model_id}"
  ]
  ecr_repository_arns = [
    var.api_ecr_repository_arn,
    var.worker_ecr_repository_arn,
  ]
  log_group_arns = [
    "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:/ecs/${var.name}/api:*",
    "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:/ecs/${var.name}/worker:*",
  ]
  ecs_cluster_arn = "arn:${local.partition}:ecs:${local.region}:${local.account_id}:cluster/${var.name}"
  ecs_service_arns = [
    "arn:${local.partition}:ecs:${local.region}:${local.account_id}:service/${var.name}/${var.name}-api",
    "arn:${local.partition}:ecs:${local.region}:${local.account_id}:service/${var.name}/${var.name}-worker",
  ]
  oidc_provider_arn = var.github_oidc_provider_arn != null ? var.github_oidc_provider_arn : aws_iam_openid_connect_provider.github[0].arn
  metrics_namespace = "LLMOps/${var.name}"

  ecs_tasks_trust_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowECSTasks"
      Effect    = "Allow"
      Action    = ["sts:AssumeRole"]
      Principal = { Service = ["ecs-tasks.amazonaws.com"] }
    }]
  })

  execution_policy_statements = concat(
    [
      {
        Sid      = "ECRAuthorization"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = ["*"]
      },
      {
        Sid    = "PullServiceImages"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
        ]
        Resource = local.ecr_repository_arns
      },
      {
        Sid    = "WriteContainerLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = local.log_group_arns
      },
    ],
    length(var.secret_arns) > 0 ? [{
      Sid      = "ReadInjectedSecrets"
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = sort(tolist(var.secret_arns))
    }] : [],
    length(var.kms_key_arns) > 0 ? [{
      Sid      = "DecryptInjectedSecrets"
      Effect   = "Allow"
      Action   = ["kms:Decrypt"]
      Resource = sort(tolist(var.kms_key_arns))
    }] : [],
  )
  execution_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = local.execution_policy_statements
  })

  runtime_data_statements = [
    {
      Sid      = "ListArtifacts"
      Effect   = "Allow"
      Action   = ["s3:ListBucket"]
      Resource = [var.artifact_bucket_arn]
    },
    {
      Sid    = "ReadWriteArtifacts"
      Effect = "Allow"
      Action = [
        "s3:GetObject",
        "s3:PutObject",
      ]
      Resource = ["${var.artifact_bucket_arn}/*"]
    },
    {
      Sid      = "PublishPlatformMetrics"
      Effect   = "Allow"
      Action   = ["cloudwatch:PutMetricData"]
      Resource = ["*"]
      Condition = {
        StringEquals = { "cloudwatch:namespace" = [local.metrics_namespace] }
      }
    },
  ]
  runtime_kms_statements = length(var.kms_key_arns) > 0 ? [{
    Sid    = "UseDataEncryptionKeys"
    Effect = "Allow"
    Action = [
      "kms:Decrypt",
      "kms:GenerateDataKey",
    ]
    Resource = sort(tolist(var.kms_key_arns))
  }] : []

  api_task_policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid    = "InvokeConfiguredModels"
          Effect = "Allow"
          Action = [
            "bedrock:InvokeModel",
            "bedrock:InvokeModelWithResponseStream",
          ]
          Resource = local.bedrock_model_arns
        },
        {
          Sid    = "SubmitInferenceJobs"
          Effect = "Allow"
          Action = [
            "sqs:GetQueueAttributes",
            "sqs:GetQueueUrl",
            "sqs:SendMessage",
          ]
          Resource = [var.inference_queue_arn]
        },
        {
          Sid    = "CreateAndReadJobState"
          Effect = "Allow"
          Action = [
            "dynamodb:DescribeTable",
            "dynamodb:GetItem",
            "dynamodb:PutItem",
            "dynamodb:UpdateItem",
          ]
          Resource = [var.job_table_arn]
        },
      ],
      local.runtime_data_statements,
      local.runtime_kms_statements,
    )
  })

  worker_task_policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid    = "InvokeConfiguredModels"
          Effect = "Allow"
          Action = [
            "bedrock:InvokeModel",
            "bedrock:InvokeModelWithResponseStream",
          ]
          Resource = local.bedrock_model_arns
        },
        {
          Sid    = "ConsumeInferenceJobs"
          Effect = "Allow"
          Action = [
            "sqs:ChangeMessageVisibility",
            "sqs:DeleteMessage",
            "sqs:GetQueueAttributes",
            "sqs:GetQueueUrl",
            "sqs:ReceiveMessage",
          ]
          Resource = [var.inference_queue_arn]
        },
        {
          Sid    = "ReadAndUpdateJobState"
          Effect = "Allow"
          Action = [
            "dynamodb:GetItem",
            "dynamodb:UpdateItem",
          ]
          Resource = [var.job_table_arn]
        },
      ],
      local.runtime_data_statements,
      local.runtime_kms_statements,
    )
  })

  github_trust_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowGitHubActions"
      Effect    = "Allow"
      Action    = ["sts:AssumeRoleWithWebIdentity"]
      Principal = { Federated = [local.oidc_provider_arn] }
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = ["sts.amazonaws.com"]
          "token.actions.githubusercontent.com:sub" = sort(tolist(var.github_oidc_subjects))
        }
      }
    }]
  })

  github_deploy_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [for statement in [
      {
        Sid      = "ECRAuthorization"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = ["*"]
      },
      {
        Sid    = "PushServiceImages"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:CompleteLayerUpload",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart",
        ]
        Resource = local.ecr_repository_arns
      },
      {
        Sid    = "EnforceImageScanGate"
        Effect = "Allow"
        Action = [
          "ecr:DescribeImages",
          "ecr:DescribeImageScanFindings",
        ]
        Resource = local.ecr_repository_arns
      },
      length(var.promotion_source_ecr_repository_arns) == 0 ? null : {
        Sid    = "ReadPromotionSources"
        Effect = "Allow"
        Action = [
          "ecr:BatchGetImage",
          "ecr:DescribeImages",
          "ecr:DescribeImageScanFindings",
        ]
        Resource = sort(tolist(var.promotion_source_ecr_repository_arns))
      },
      {
        Sid    = "RegisterTaskDefinitions"
        Effect = "Allow"
        Action = [
          "ecs:DescribeTaskDefinition",
          "ecs:RegisterTaskDefinition",
        ]
        Resource = ["*"]
      },
      {
        Sid    = "DeployServices"
        Effect = "Allow"
        Action = [
          "ecs:DescribeServices",
          "ecs:UpdateService",
        ]
        Resource = local.ecs_service_arns
      },
      {
        Sid      = "DescribeCluster"
        Effect   = "Allow"
        Action   = ["ecs:DescribeClusters"]
        Resource = [local.ecs_cluster_arn]
      },
      {
        Sid    = "PassOnlyPlatformRoles"
        Effect = "Allow"
        Action = ["iam:PassRole"]
        Resource = [
          aws_iam_role.execution.arn,
          aws_iam_role.api_task.arn,
          aws_iam_role.worker_task.arn,
        ]
        Condition = {
          StringEquals = { "iam:PassedToService" = ["ecs-tasks.amazonaws.com"] }
        }
      },
    ] : statement if statement != null]
  })
}

resource "aws_iam_role" "execution" {
  name               = "${var.name}-execution"
  assume_role_policy = local.ecs_tasks_trust_policy
  tags               = merge(var.tags, { Role = "ecs-execution" })
}

resource "aws_iam_role_policy" "execution" {
  name   = "${var.name}-execution"
  role   = aws_iam_role.execution.id
  policy = local.execution_policy
}

resource "aws_iam_role" "api_task" {
  name               = "${var.name}-api-task"
  assume_role_policy = local.ecs_tasks_trust_policy
  tags               = merge(var.tags, { Role = "api-task" })
}

resource "aws_iam_role_policy" "api_task" {
  name   = "${var.name}-api-task"
  role   = aws_iam_role.api_task.id
  policy = local.api_task_policy
}

resource "aws_iam_role" "worker_task" {
  name               = "${var.name}-worker-task"
  assume_role_policy = local.ecs_tasks_trust_policy
  tags               = merge(var.tags, { Role = "worker-task" })
}

resource "aws_iam_role_policy" "worker_task" {
  name   = "${var.name}-worker-task"
  role   = aws_iam_role.worker_task.id
  policy = local.worker_task_policy
}

resource "aws_iam_openid_connect_provider" "github" {
  count = var.github_oidc_provider_arn == null ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  tags           = merge(var.tags, { Name = "github-actions" })
}

resource "aws_iam_role" "github_deploy" {
  name                 = "${var.name}-github-deploy"
  assume_role_policy   = local.github_trust_policy
  max_session_duration = 3600
  tags                 = merge(var.tags, { Role = "github-deploy" })
}

resource "aws_iam_role_policy" "github_deploy" {
  name   = "${var.name}-github-deploy"
  role   = aws_iam_role.github_deploy.id
  policy = local.github_deploy_policy
}

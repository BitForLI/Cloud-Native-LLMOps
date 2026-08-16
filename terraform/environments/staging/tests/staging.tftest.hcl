mock_provider "aws" {
  mock_resource "aws_wafv2_web_acl" {
    defaults = {
      arn = "arn:aws:wafv2:ap-southeast-2:123456789012:regional/webacl/mock/00000000-0000-0000-0000-000000000000"
    }
  }

  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:ap-southeast-2:123456789012:log-group:aws-waf-logs-mock"
    }
  }
}

variables {
  availability_zones       = ["ap-southeast-2a", "ap-southeast-2b"]
  github_oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
  promotion_source_ecr_repository_arns = [
    "arn:aws:ecr:ap-southeast-2:123456789012:repository/cloud-native-llmops/dev/api",
    "arn:aws:ecr:ap-southeast-2:123456789012:repository/cloud-native-llmops/dev/worker",
  ]
  alb_certificate_arn = "arn:aws:acm:ap-southeast-2:123456789012:certificate/00000000-0000-0000-0000-000000000000"
}

run "production_like_staging_defaults" {
  command = plan

  assert {
    condition     = length(output.nat_gateway_ids) == 2
    error_message = "Staging must keep independent NAT capacity in every AZ."
  }

  assert {
    condition     = startswith(output.api_url, "https://")
    error_message = "Staging must expose HTTPS only."
  }

  assert {
    condition = toset(keys(output.deployment_github_variables)) == toset([
      "API_ECS_SERVICE",
      "API_AUTH_SECRET_ID",
      "API_URL",
      "AWS_ACCOUNT_ID",
      "AWS_DEPLOY_ROLE_ARN",
      "AWS_REGION",
      "ECS_CLUSTER",
      "STAGING_API_ECR_REPOSITORY",
      "STAGING_WORKER_ECR_REPOSITORY",
      "WORKER_ECS_SERVICE",
    ])
    error_message = "Staging must expose the complete non-secret promotion configuration."
  }

  assert {
    condition = (
      output.staging_safety_profile.nat_gateway_mode == "per_az" &&
      output.staging_safety_profile.api_desired_count >= 2 &&
      output.staging_safety_profile.worker_desired_count >= 2 &&
      output.staging_safety_profile.log_retention_days >= 90 &&
      output.staging_safety_profile.data_deletion_protection &&
      output.staging_safety_profile.load_balancer_protection &&
      output.staging_safety_profile.encrypted_api_auth &&
      output.staging_safety_profile.trace_sample_ratio == 1 &&
      endswith(output.staging_safety_profile.adot_collector_image, ":v0.48.0") &&
      output.staging_safety_profile.autoscaling_bounds.api.min == 2 &&
      output.staging_safety_profile.autoscaling_bounds.api.max == 6 &&
      output.staging_safety_profile.autoscaling_bounds.worker.min == 2 &&
      output.staging_safety_profile.autoscaling_bounds.worker.max == 10 &&
      output.staging_safety_profile.worker_backlog_target == 2 &&
      output.staging_safety_profile.waf_enabled &&
      startswith(output.staging_safety_profile.waf_log_group, "aws-waf-logs-") &&
      output.staging_safety_profile.waf_rate_limit == 1000 &&
      output.staging_safety_profile.waf_alarm_name != null
    )
    error_message = "Staging safety controls must remain production-like."
  }
}

run "promotion_role_is_source_scoped" {
  command = apply

  module { source = "../../modules/iam" }

  variables {
    name                      = "llmops-staging"
    api_ecr_repository_arn    = "arn:aws:ecr:ap-southeast-2:123456789012:repository/llmops/staging/api"
    worker_ecr_repository_arn = "arn:aws:ecr:ap-southeast-2:123456789012:repository/llmops/staging/worker"
    promotion_source_ecr_repository_arns = [
      "arn:aws:ecr:ap-southeast-2:123456789012:repository/llmops/dev/api",
      "arn:aws:ecr:ap-southeast-2:123456789012:repository/llmops/dev/worker",
    ]
    promotion_only                   = true
    artifact_bucket_arn              = "arn:aws:s3:::llmops-staging-artifacts"
    job_table_arn                    = "arn:aws:dynamodb:ap-southeast-2:123456789012:table/llmops-staging-jobs"
    inference_queue_arn              = "arn:aws:sqs:ap-southeast-2:123456789012:llmops-staging-inference"
    bedrock_model_ids                = ["test-model"]
    secret_arns                      = ["arn:aws:secretsmanager:ap-southeast-2:123456789012:secret:llmops-staging/api-auth-token-AbCdEf"]
    secret_kms_key_arns              = ["arn:aws:kms:ap-southeast-2:123456789012:key/00000000-0000-0000-0000-000000000000"]
    github_verification_secret_arns  = ["arn:aws:secretsmanager:ap-southeast-2:123456789012:secret:llmops-staging/api-auth-token-AbCdEf"]
    github_verification_kms_key_arns = ["arn:aws:kms:ap-southeast-2:123456789012:key/00000000-0000-0000-0000-000000000000"]
    github_oidc_provider_arn         = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    github_oidc_subjects             = ["repo:BitForLI@218609705/Cloud-Native-LLMOps@1320235086:environment:staging"]
  }

  assert {
    condition = (
      strcontains(local.github_trust_policy, ":environment:staging") &&
      length(one([for statement in jsondecode(local.github_deploy_policy).Statement : statement if statement.Sid == "ReadPromotionSources"]).Resource) == 2 &&
      contains(one([for statement in jsondecode(local.github_deploy_policy).Statement : statement if statement.Sid == "ReadPromotionSources"]).Action, "ecr:BatchGetImage") &&
      one([for statement in jsondecode(local.github_deploy_policy).Statement : statement if statement.Sid == "PushServiceImages"]).Action == ["ecr:PutImage"] &&
      one([for statement in jsondecode(local.github_deploy_policy).Statement : statement if statement.Sid == "ReadReleaseVerificationSecret"]).Resource == ["arn:aws:secretsmanager:ap-southeast-2:123456789012:secret:llmops-staging/api-auth-token-AbCdEf"] &&
      one([for statement in jsondecode(local.github_deploy_policy).Statement : statement if statement.Sid == "DecryptReleaseVerificationSecret"]).Resource == ["arn:aws:kms:ap-southeast-2:123456789012:key/00000000-0000-0000-0000-000000000000"]
    )
    error_message = "Promotion role must trust staging and read exactly two source repositories."
  }

  assert {
    condition = (
      one([for statement in jsondecode(local.execution_policy).Statement : statement if statement.Sid == "DecryptInjectedSecrets"]).Resource == ["arn:aws:kms:ap-southeast-2:123456789012:key/00000000-0000-0000-0000-000000000000"] &&
      length([for statement in jsondecode(local.api_task_policy).Statement : statement if statement.Sid == "UseDataEncryptionKeys"]) == 0 &&
      length([for statement in jsondecode(local.worker_task_policy).Statement : statement if statement.Sid == "UseDataEncryptionKeys"]) == 0
    )
    error_message = "Only the ECS execution role may decrypt the injected API secret."
  }
}

run "rejects_single_nat_staging" {
  command = plan
  variables { nat_gateway_mode = "single" }
  expect_failures = [var.nat_gateway_mode]
}

run "rejects_underprovisioned_staging" {
  command = plan
  variables {
    api_desired_count    = 1
    worker_desired_count = 1
  }
  expect_failures = [var.api_desired_count, var.worker_desired_count]
}

run "rejects_branch_oidc_subject" {
  command = plan
  variables {
    github_oidc_subjects = ["repo:BitForLI@218609705/Cloud-Native-LLMOps@1320235086:ref:refs/heads/master"]
  }
  expect_failures = [var.github_oidc_subjects]
}

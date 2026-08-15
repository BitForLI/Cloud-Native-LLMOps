mock_provider "aws" {
  mock_resource "aws_iam_role" {
    defaults = {
      arn  = "arn:aws:iam::123456789012:role/mock-role"
      name = "mock-role"
    }
  }
}

variables {
  availability_zones       = ["ap-southeast-2a", "ap-southeast-2b", "ap-southeast-2c"]
  github_oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
  promotion_source_ecr_repository_arns = [
    "arn:aws:ecr:ap-southeast-2:123456789012:repository/cloud-native-llmops/staging/api",
    "arn:aws:ecr:ap-southeast-2:123456789012:repository/cloud-native-llmops/staging/worker",
  ]
  alb_certificate_arn       = "arn:aws:acm:ap-southeast-2:123456789012:certificate/00000000-0000-0000-0000-000000000000"
  alarm_notification_emails = ["platform@example.com"]
}

run "resilient_production_defaults" {
  command = plan

  assert {
    condition = (
      output.production_safety_profile.availability_zone_count == 3 &&
      output.production_safety_profile.nat_gateway_count == 3 &&
      output.production_safety_profile.api_desired_count >= 2 &&
      output.production_safety_profile.worker_desired_count >= 2 &&
      output.production_safety_profile.log_retention_days >= 365 &&
      output.production_safety_profile.data_deletion_protection &&
      output.production_safety_profile.load_balancer_protection &&
      output.production_safety_profile.api_alternate_target_group &&
      output.production_safety_profile.encrypted_api_auth &&
      output.production_safety_profile.trace_sample_ratio == 0.1 &&
      endswith(output.production_safety_profile.adot_collector_image, ":v0.48.0") &&
      output.production_safety_profile.autoscaling_bounds.api.min == 3 &&
      output.production_safety_profile.autoscaling_bounds.api.max == 12 &&
      output.production_safety_profile.autoscaling_bounds.worker.min == 2 &&
      output.production_safety_profile.autoscaling_bounds.worker.max == 30 &&
      output.production_safety_profile.worker_backlog_target == 2
    )
    error_message = "Production must preserve multi-AZ capacity, retention, deletion protection, and two target groups."
  }

  assert {
    condition = (
      output.production_safety_profile.deployment_config == "CodeDeployDefault.ECSCanary10Percent5Minutes" &&
      output.production_safety_profile.blue_termination_wait >= 5
    )
    error_message = "Production must keep a 10 percent canary and a blue bake window."
  }

  assert {
    condition     = length(output.deployment_alarm_names.api) == 7
    error_message = "CodeDeploy must monitor both blue and green ALB error and latency signals."
  }

  assert {
    condition = toset(keys(output.deployment_github_variables)) == toset([
      "API_ECS_SERVICE",
      "API_AUTH_SECRET_ID",
      "API_URL",
      "AWS_ACCOUNT_ID",
      "AWS_DEPLOY_ROLE_ARN",
      "AWS_REGION",
      "CODEDEPLOY_APPLICATION",
      "CODEDEPLOY_DEPLOYMENT_GROUP",
      "ECS_CLUSTER",
      "PRODUCTION_API_ECR_REPOSITORY",
      "PRODUCTION_WORKER_ECR_REPOSITORY",
      "WORKER_ECS_SERVICE",
    ])
    error_message = "Production must expose the complete non-secret release configuration."
  }
}

run "codedeploy_canary_rolls_back_on_alarms" {
  command = apply

  module { source = "../../modules/codedeploy" }

  variables {
    name                     = "llmops-production"
    ecs_cluster_name         = "llmops-production"
    ecs_service_name         = "llmops-production-api"
    production_listener_arns = ["arn:aws:elasticloadbalancing:ap-southeast-2:123456789012:listener/app/prod/id/listener"]
    target_group_names       = ["prod-blue", "prod-green"]
    alarm_names              = ["prod-api-errors", "prod-api-latency"]
  }

  assert {
    condition = (
      aws_codedeploy_app.api.compute_platform == "ECS" &&
      aws_codedeploy_deployment_group.api.deployment_config_name == "CodeDeployDefault.ECSCanary10Percent5Minutes" &&
      one(aws_codedeploy_deployment_group.api.deployment_style).deployment_type == "BLUE_GREEN" &&
      one(aws_codedeploy_deployment_group.api.deployment_style).deployment_option == "WITH_TRAFFIC_CONTROL"
    )
    error_message = "The API deployment group must perform a 10 percent ECS blue/green canary."
  }

  assert {
    condition = (
      one(aws_codedeploy_deployment_group.api.alarm_configuration).enabled &&
      !one(aws_codedeploy_deployment_group.api.alarm_configuration).ignore_poll_alarm_failure &&
      toset(one(aws_codedeploy_deployment_group.api.alarm_configuration).alarms) == toset(["prod-api-errors", "prod-api-latency"])
    )
    error_message = "CodeDeploy must fail closed when release alarms cannot be polled or enter ALARM."
  }

  assert {
    condition = (
      one(aws_codedeploy_deployment_group.api.auto_rollback_configuration).enabled &&
      contains(one(aws_codedeploy_deployment_group.api.auto_rollback_configuration).events, "DEPLOYMENT_FAILURE") &&
      contains(one(aws_codedeploy_deployment_group.api.auto_rollback_configuration).events, "DEPLOYMENT_STOP_ON_ALARM")
    )
    error_message = "Failed or alarmed deployments must automatically roll back."
  }

  assert {
    condition = (
      length(one(one(aws_codedeploy_deployment_group.api.load_balancer_info).target_group_pair_info).target_group) == 2 &&
      one(one(aws_codedeploy_deployment_group.api.blue_green_deployment_config).terminate_blue_instances_on_deployment_success).termination_wait_time_in_minutes >= 5
    )
    error_message = "Blue/green requires two target groups and a post-shift bake window."
  }
}

run "production_role_cannot_bypass_artifact_or_api_release" {
  command = apply

  module { source = "../../modules/iam" }

  variables {
    name                      = "llmops-production"
    api_ecr_repository_arn    = "arn:aws:ecr:ap-southeast-2:123456789012:repository/llmops/production/api"
    worker_ecr_repository_arn = "arn:aws:ecr:ap-southeast-2:123456789012:repository/llmops/production/worker"
    promotion_source_ecr_repository_arns = [
      "arn:aws:ecr:ap-southeast-2:123456789012:repository/llmops/staging/api",
      "arn:aws:ecr:ap-southeast-2:123456789012:repository/llmops/staging/worker",
    ]
    promotion_only                   = true
    github_api_update_enabled        = false
    artifact_bucket_arn              = "arn:aws:s3:::llmops-production-artifacts"
    job_table_arn                    = "arn:aws:dynamodb:ap-southeast-2:123456789012:table/llmops-production-jobs"
    inference_queue_arn              = "arn:aws:sqs:ap-southeast-2:123456789012:llmops-production-inference"
    bedrock_model_ids                = ["test-model"]
    secret_arns                      = ["arn:aws:secretsmanager:ap-southeast-2:123456789012:secret:llmops-production/api-auth-token-AbCdEf"]
    secret_kms_key_arns              = ["arn:aws:kms:ap-southeast-2:123456789012:key/00000000-0000-0000-0000-000000000000"]
    github_verification_secret_arns  = ["arn:aws:secretsmanager:ap-southeast-2:123456789012:secret:llmops-production/api-auth-token-AbCdEf"]
    github_verification_kms_key_arns = ["arn:aws:kms:ap-southeast-2:123456789012:key/00000000-0000-0000-0000-000000000000"]
    github_oidc_provider_arn         = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    github_oidc_subjects             = ["repo:BitForLI@218609705/Cloud-Native-LLMOps@1320235086:environment:production"]
  }

  assert {
    condition = (
      one([for statement in jsondecode(local.github_deploy_policy).Statement : statement if statement.Sid == "PushServiceImages"]).Action == ["ecr:PutImage"] &&
      length(one([for statement in jsondecode(local.github_deploy_policy).Statement : statement if statement.Sid == "UpdateDeploymentServices"]).Resource) == 1 &&
      endswith(one(one([for statement in jsondecode(local.github_deploy_policy).Statement : statement if statement.Sid == "UpdateDeploymentServices"]).Resource), "-worker") &&
      length([for statement in jsondecode(local.github_deploy_policy).Statement : statement if statement.Sid == "ReadReleaseVerificationSecret"]) == 1 &&
      length([for statement in jsondecode(local.github_deploy_policy).Statement : statement if statement.Sid == "DecryptReleaseVerificationSecret"]) == 1
    )
    error_message = "Production automation may only copy manifests and directly update the Worker service."
  }
}

run "rejects_underprovisioned_production" {
  command = plan
  variables {
    api_desired_count    = 1
    worker_desired_count = 1
  }
  expect_failures = [var.api_desired_count, var.worker_desired_count]
}

run "rejects_unprotected_production_identity" {
  command = plan
  variables {
    github_oidc_subjects = ["repo:BitForLI@218609705/Cloud-Native-LLMOps@1320235086:ref:refs/heads/master"]
  }
  expect_failures = [var.github_oidc_subjects]
}

run "rejects_missing_alarm_recipient" {
  command = plan
  variables { alarm_notification_emails = [] }
  expect_failures = [var.alarm_notification_emails]
}

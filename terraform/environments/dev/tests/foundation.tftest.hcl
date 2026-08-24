mock_provider "aws" {
  mock_resource "aws_secretsmanager_secret" {
    defaults = {
      arn = "arn:aws:secretsmanager:ap-southeast-2:123456789012:secret:mock-api-auth-AbCdEf"
    }
  }

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

run "single_nat_development_topology" {
  command = plan

  variables {
    availability_zones = ["ap-southeast-2a", "ap-southeast-2b"]
    nat_gateway_mode   = "single"
  }

  assert {
    condition     = length(output.public_subnet_ids) == 2
    error_message = "Development must create one public subnet per configured AZ."
  }

  assert {
    condition     = length(output.private_subnet_ids) == 2
    error_message = "Development must create one private subnet per configured AZ."
  }

  assert {
    condition     = length(output.nat_gateway_ids) == 1
    error_message = "single mode must create exactly one NAT gateway."
  }

  assert {
    condition = toset(keys(output.deployment_github_variables)) == toset([
      "API_ECR_REPOSITORY",
      "API_ECS_SERVICE",
      "API_URL",
      "AWS_ACCOUNT_ID",
      "AWS_DEPLOY_ROLE_ARN",
      "AWS_REGION",
      "ECS_CLUSTER",
      "WORKER_ECR_REPOSITORY",
      "WORKER_ECS_SERVICE",
    ])
    error_message = "Terraform must expose the complete non-secret GitHub deployment configuration."
  }
}

run "per_az_nat_topology" {
  command = plan

  variables {
    availability_zones = ["ap-southeast-2a", "ap-southeast-2b"]
    nat_gateway_mode   = "per_az"
  }

  assert {
    condition     = length(output.nat_gateway_ids) == 2
    error_message = "per_az mode must create one NAT gateway per configured AZ."
  }
}

run "isolated_topology_without_nat" {
  command = plan

  variables {
    availability_zones = ["ap-southeast-2a", "ap-southeast-2b"]
    nat_gateway_mode   = "none"
  }

  assert {
    condition     = length(output.nat_gateway_ids) == 0
    error_message = "none mode must not create NAT gateways."
  }
}

run "rejects_invalid_nat_mode" {
  command = plan

  variables {
    availability_zones = ["ap-southeast-2a", "ap-southeast-2b"]
    nat_gateway_mode   = "invalid"
  }

  expect_failures = [var.nat_gateway_mode]
}

run "rejects_ipv6_vpc_cidr" {
  command = plan

  variables {
    availability_zones = ["ap-southeast-2a", "ap-southeast-2b"]
    vpc_cidr           = "2001:db8::/56"
  }

  expect_failures = [var.vpc_cidr]
}

run "rejects_vpc_too_small_for_subnet_plan" {
  command = plan

  variables {
    availability_zones = ["ap-southeast-2a", "ap-southeast-2b"]
    vpc_cidr           = "10.20.0.0/28"
  }

  expect_failures = [var.vpc_cidr]
}

run "rejects_duplicate_availability_zones" {
  command = plan

  variables {
    availability_zones = ["ap-southeast-2a", "ap-southeast-2a"]
  }

  expect_failures = [var.availability_zones]
}

run "data_security_defaults" {
  command = apply

  module {
    source = "../../modules/database"
  }

  variables {
    name = "llmops-test"
  }

  assert {
    condition     = aws_s3_bucket_public_access_block.artifacts.block_public_acls
    error_message = "The artifact bucket must block public ACLs."
  }

  assert {
    condition     = aws_s3_bucket_public_access_block.artifacts.block_public_policy
    error_message = "The artifact bucket must block public bucket policies."
  }

  assert {
    condition     = aws_s3_bucket_versioning.artifacts.versioning_configuration[0].status == "Enabled"
    error_message = "Artifact versioning must be enabled."
  }

  assert {
    condition     = one(one(aws_s3_bucket_server_side_encryption_configuration.artifacts.rule).apply_server_side_encryption_by_default).sse_algorithm == "AES256"
    error_message = "Artifacts must use server-side encryption by default."
  }

  assert {
    condition     = jsondecode(aws_s3_bucket_policy.require_tls.policy).Statement[0].Condition.Bool["aws:SecureTransport"] == "false"
    error_message = "The bucket policy must deny non-TLS transport."
  }

  assert {
    condition     = aws_dynamodb_table.jobs.billing_mode == "PAY_PER_REQUEST"
    error_message = "The development job table must use on-demand billing."
  }

  assert {
    condition     = aws_dynamodb_table.jobs.ttl[0].enabled
    error_message = "Job TTL must be enabled."
  }

  assert {
    condition     = aws_dynamodb_table.jobs.server_side_encryption[0].enabled
    error_message = "The job table must use server-side encryption."
  }

  assert {
    condition     = aws_dynamodb_table.jobs.point_in_time_recovery[0].enabled
    error_message = "The job table must enable point-in-time recovery."
  }
}

run "queue_resilience_defaults" {
  command = apply

  module {
    source = "../../modules/queue"
  }

  variables {
    name = "llmops-test"
  }

  assert {
    condition     = aws_sqs_queue.inference.sqs_managed_sse_enabled
    error_message = "The inference queue must be encrypted by default."
  }

  assert {
    condition     = aws_sqs_queue.inference.receive_wait_time_seconds == 20
    error_message = "The inference queue must use long polling."
  }

  assert {
    condition     = aws_sqs_queue.inference.visibility_timeout_seconds == 180
    error_message = "Visibility timeout must cover a normal inference attempt."
  }

  assert {
    condition     = jsondecode(aws_sqs_queue.inference.redrive_policy).maxReceiveCount == 5
    error_message = "The inference queue must redrive poison messages after bounded retries."
  }

  assert {
    condition     = jsondecode(aws_sqs_queue_redrive_allow_policy.dead_letter.redrive_allow_policy).sourceQueueArns == [aws_sqs_queue.inference.arn]
    error_message = "The DLQ must only accept redrive from the inference queue."
  }
}

run "secret_values_stay_out_of_terraform_state" {
  command = apply

  module { source = "../../modules/secrets" }

  variables {
    name = "llmops-production"
  }

  assert {
    condition = (
      aws_kms_key.secrets.enable_key_rotation &&
      aws_kms_key.secrets.deletion_window_in_days == 30 &&
      aws_secretsmanager_secret.api_auth_token.kms_key_id == aws_kms_key.secrets.arn &&
      aws_secretsmanager_secret.api_auth_token.recovery_window_in_days == 30 &&
      aws_secretsmanager_secret_policy.api_auth_token.block_public_policy
    )
    error_message = "Application secrets must use a rotating CMK, recovery windows, and public-policy blocking."
  }

  assert {
    condition     = !strcontains(jsonencode(aws_secretsmanager_secret.api_auth_token), "secret_string")
    error_message = "The module must never place a secret value in Terraform state."
  }
}

run "rejects_irrecoverable_secret_windows" {
  command = plan

  module { source = "../../modules/secrets" }

  variables {
    name                        = "llmops-dev"
    kms_deletion_window_days    = 6
    secret_recovery_window_days = 0
  }

  expect_failures = [
    var.kms_deletion_window_days,
    var.secret_recovery_window_days,
  ]
}

run "rejects_dlq_retention_shorter_than_source" {
  command = plan

  module {
    source = "../../modules/queue"
  }

  variables {
    name                          = "llmops-test"
    message_retention_seconds     = 345600
    dead_letter_retention_seconds = 86400
  }

  expect_failures = [var.dead_letter_retention_seconds]
}

run "iam_separates_runtime_and_deployment_permissions" {
  command = apply

  module {
    source = "../../modules/iam"
  }

  variables {
    name                         = "llmops-test"
    api_ecr_repository_arn       = "arn:aws:ecr:ap-southeast-2:123456789012:repository/llmops/api"
    worker_ecr_repository_arn    = "arn:aws:ecr:ap-southeast-2:123456789012:repository/llmops/worker"
    artifact_bucket_arn          = "arn:aws:s3:::llmops-artifacts"
    job_table_arn                = "arn:aws:dynamodb:ap-southeast-2:123456789012:table/llmops-jobs"
    inference_queue_arn          = "arn:aws:sqs:ap-southeast-2:123456789012:llmops-inference"
    bedrock_model_ids            = ["anthropic.claude-haiku-4-5-20251001-v1:0"]
    bedrock_inference_profile_id = "au.anthropic.claude-haiku-4-5-20251001-v1:0"
    bedrock_inference_regions    = ["ap-southeast-2", "ap-southeast-4"]
    github_oidc_subjects = [
      "repo:BitForLI@218609705/Cloud-Native-LLMOps@1320235086:ref:refs/heads/master"
    ]
  }

  assert {
    condition = contains(
      one([for statement in jsondecode(local.api_task_policy).Statement : statement if statement.Sid == "SubmitInferenceJobs"]).Action,
      "sqs:SendMessage"
    )
    error_message = "The API role must be able to submit inference jobs."
  }

  assert {
    condition = alltrue([
      for action in ["dynamodb:DescribeTable", "dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem"] :
      contains(
        one([for statement in jsondecode(local.api_task_policy).Statement : statement if statement.Sid == "CreateAndReadJobState"]).Action,
        action
      )
    ])
    error_message = "The API role must support durable job creation, readiness, reads, and enqueue failure updates."
  }

  assert {
    condition = !contains(
      one([for statement in jsondecode(local.api_task_policy).Statement : statement if statement.Sid == "SubmitInferenceJobs"]).Action,
      "sqs:ReceiveMessage"
    )
    error_message = "The API role must not consume inference jobs."
  }

  assert {
    condition = contains(
      one([for statement in jsondecode(local.worker_task_policy).Statement : statement if statement.Sid == "ConsumeInferenceJobs"]).Action,
      "sqs:ReceiveMessage"
    )
    error_message = "The Worker role must be able to consume inference jobs."
  }

  assert {
    condition = !contains(
      one([for statement in jsondecode(local.worker_task_policy).Statement : statement if statement.Sid == "ConsumeInferenceJobs"]).Action,
      "sqs:SendMessage"
    )
    error_message = "The Worker role must not submit inference jobs."
  }

  assert {
    condition = (
      length(one([for statement in jsondecode(local.api_task_policy).Statement : statement if statement.Sid == "InvokeConfiguredModels"]).Resource) == 3 &&
      length([for arn in one([for statement in jsondecode(local.api_task_policy).Statement : statement if statement.Sid == "InvokeConfiguredModels"]).Resource : arn if endswith(arn, ":inference-profile/au.anthropic.claude-haiku-4-5-20251001-v1:0")]) == 1 &&
      length([for arn in one([for statement in jsondecode(local.api_task_policy).Statement : statement if statement.Sid == "InvokeConfiguredModels"]).Resource : arn if endswith(arn, ":ap-southeast-2::foundation-model/anthropic.claude-haiku-4-5-20251001-v1:0")]) == 1 &&
      length([for arn in one([for statement in jsondecode(local.api_task_policy).Statement : statement if statement.Sid == "InvokeConfiguredModels"]).Resource : arn if endswith(arn, ":ap-southeast-4::foundation-model/anthropic.claude-haiku-4-5-20251001-v1:0")]) == 1
    )
    error_message = "Bedrock invocation must be scoped to the configured AU inference profile and its exact destination models."
  }

  assert {
    condition = strcontains(
      local.github_trust_policy,
      "repo:BitForLI@218609705/Cloud-Native-LLMOps@1320235086:ref:refs/heads/master"
    ) && !strcontains(local.github_trust_policy, "repo:BitForLI/*")
    error_message = "GitHub trust must use an exact immutable repository subject."
  }

  assert {
    condition = length(
      one([for statement in jsondecode(local.github_deploy_policy).Statement : statement if statement.Sid == "PassOnlyPlatformRoles"]).Resource
    ) == 3
    error_message = "GitHub may only pass the three platform ECS roles."
  }

  assert {
    condition = alltrue([
      for action in ["ecr:DescribeImages", "ecr:DescribeImageScanFindings"] :
      contains(
        one([for statement in jsondecode(local.github_deploy_policy).Statement : statement if statement.Sid == "EnforceImageScanGate"]).Action,
        action
      )
    ])
    error_message = "GitHub must read ECR vulnerability results before deployment."
  }

  assert {
    condition = (
      !contains(
        one([for statement in jsondecode(local.github_deploy_policy).Statement : statement if statement.Sid == "EnforceImageScanGate"]).Action,
        "ecr:DeleteRepository"
      ) &&
      length(one([for statement in jsondecode(local.github_deploy_policy).Statement : statement if statement.Sid == "EnforceImageScanGate"]).Resource) == 2
    )
    error_message = "The scan gate must remain read-only and scoped to both service repositories."
  }

  assert {
    condition     = length([for statement in jsondecode(local.github_deploy_policy).Statement : statement if statement.Sid == "ReadPromotionSources"]) == 0
    error_message = "Development must not receive cross-environment source repository access."
  }

  assert {
    condition = one(one(
      [for statement in jsondecode(local.github_deploy_policy).Statement : statement if statement.Sid == "PassOnlyPlatformRoles"]
    ).Condition.StringEquals["iam:PassedToService"]) == "ecs-tasks.amazonaws.com"
    error_message = "PassRole must be restricted to ECS tasks."
  }

  assert {
    condition     = aws_iam_openid_connect_provider.github[0].client_id_list == toset(["sts.amazonaws.com"])
    error_message = "The GitHub OIDC provider audience must be AWS STS."
  }

  assert {
    condition = (
      length(local.execution_policy) <= 10240 &&
      length(local.api_task_policy) <= 10240 &&
      length(local.worker_task_policy) <= 10240 &&
      length(local.github_deploy_policy) <= 10240
    )
    error_message = "Every inline role policy must stay within the IAM 10240-character quota."
  }

  assert {
    condition = alltrue([
      for policy in [local.api_task_policy, local.worker_task_policy] : (
        one([for statement in jsondecode(policy).Statement : statement if statement.Sid == "PublishApplicationTraces"]).Action == [
          "xray:PutTelemetryRecords",
          "xray:PutTraceSegments",
        ] &&
        one([for statement in jsondecode(policy).Statement : statement if statement.Sid == "PublishApplicationTraces"]).Resource == ["*"]
      )
    ])
    error_message = "Both task roles need only the X-Ray write actions required by their collector sidecars."
  }
}

run "rejects_wildcard_github_subject" {
  command = plan

  module {
    source = "../../modules/iam"
  }

  variables {
    name                      = "llmops-test"
    api_ecr_repository_arn    = "arn:aws:ecr:ap-southeast-2:123456789012:repository/llmops/api"
    worker_ecr_repository_arn = "arn:aws:ecr:ap-southeast-2:123456789012:repository/llmops/worker"
    artifact_bucket_arn       = "arn:aws:s3:::llmops-artifacts"
    job_table_arn             = "arn:aws:dynamodb:ap-southeast-2:123456789012:table/llmops-jobs"
    inference_queue_arn       = "arn:aws:sqs:ap-southeast-2:123456789012:llmops-inference"
    bedrock_model_ids         = ["test-model"]
    github_oidc_subjects      = ["repo:BitForLI/*"]
  }

  expect_failures = [var.github_oidc_subjects]
}

run "rejects_wildcard_bedrock_model" {
  command = plan

  module {
    source = "../../modules/iam"
  }

  variables {
    name                      = "llmops-test"
    api_ecr_repository_arn    = "arn:aws:ecr:ap-southeast-2:123456789012:repository/llmops/api"
    worker_ecr_repository_arn = "arn:aws:ecr:ap-southeast-2:123456789012:repository/llmops/worker"
    artifact_bucket_arn       = "arn:aws:s3:::llmops-artifacts"
    job_table_arn             = "arn:aws:dynamodb:ap-southeast-2:123456789012:table/llmops-jobs"
    inference_queue_arn       = "arn:aws:sqs:ap-southeast-2:123456789012:llmops-inference"
    bedrock_model_ids         = ["*"]
    github_oidc_subjects      = ["repo:example/repository:ref:refs/heads/main"]
  }

  expect_failures = [var.bedrock_model_ids]
}

run "rejects_signing_without_a_promotion_boundary" {
  command = plan

  module {
    source = "../../modules/iam"
  }

  variables {
    name                         = "llmops-test"
    api_ecr_repository_arn       = "arn:aws:ecr:ap-southeast-2:123456789012:repository/llmops/api"
    worker_ecr_repository_arn    = "arn:aws:ecr:ap-southeast-2:123456789012:repository/llmops/worker"
    artifact_bucket_arn          = "arn:aws:s3:::llmops-artifacts"
    job_table_arn                = "arn:aws:dynamodb:ap-southeast-2:123456789012:table/llmops-jobs"
    inference_queue_arn          = "arn:aws:sqs:ap-southeast-2:123456789012:llmops-inference"
    bedrock_model_ids            = ["test-model"]
    github_oidc_subjects         = ["repo:example/repository:ref:refs/heads/main"]
    supply_chain_signing_enabled = true
  }

  expect_failures = [var.supply_chain_signing_enabled]
}

run "alb_http_development_boundary" {
  command = plan

  module {
    source = "../../modules/alb"
  }

  variables {
    name              = "llmops-test"
    vpc_id            = "vpc-0123456789abcdef0"
    vpc_cidr          = "10.20.0.0/16"
    public_subnet_ids = ["subnet-public-a", "subnet-public-b"]
  }

  assert {
    condition     = !aws_lb.this.internal && aws_lb.this.drop_invalid_header_fields
    error_message = "The ALB must be public and drop invalid headers."
  }

  assert {
    condition     = aws_lb_target_group.api.target_type == "ip"
    error_message = "Fargate targets must use the ip target type."
  }

  assert {
    condition     = one(aws_lb_target_group.api.health_check).path == "/health"
    error_message = "The API target group must use the health endpoint."
  }

  assert {
    condition     = length(aws_lb_listener.http_forward) == 1 && length(aws_lb_listener.https) == 0
    error_message = "Certificate-free development must expose only the forwarding HTTP listener."
  }
}

run "alb_https_redirect_boundary" {
  command = plan

  module {
    source = "../../modules/alb"
  }

  variables {
    name              = "llmops-test"
    vpc_id            = "vpc-0123456789abcdef0"
    vpc_cidr          = "10.20.0.0/16"
    public_subnet_ids = ["subnet-public-a", "subnet-public-b"]
    certificate_arn   = "arn:aws:acm:ap-southeast-2:123456789012:certificate/00000000-0000-0000-0000-000000000000"
  }

  assert {
    condition     = length(aws_lb_listener.http_redirect) == 1 && length(aws_lb_listener.https) == 1
    error_message = "A certificate must enable HTTPS and redirect HTTP."
  }

  assert {
    condition     = aws_lb_listener.https[0].ssl_policy == "ELBSecurityPolicy-TLS13-1-2-Res-2021-06"
    error_message = "HTTPS must use the configured TLS 1.2/1.3 policy."
  }
}

run "ecs_hardens_private_api_and_worker_services" {
  command = plan

  module {
    source = "../../modules/ecs"
  }

  variables {
    name                  = "llmops-test"
    environment           = "test"
    aws_region            = "ap-southeast-2"
    vpc_id                = "vpc-0123456789abcdef0"
    private_subnet_ids    = ["subnet-private-a", "subnet-private-b"]
    alb_security_group_id = "sg-0123456789abcdef0"
    api_target_group_arn  = "arn:aws:elasticloadbalancing:ap-southeast-2:123456789012:targetgroup/llmops-api/0000000000000000"
    api_repository_url    = "123456789012.dkr.ecr.ap-southeast-2.amazonaws.com/llmops/api"
    worker_repository_url = "123456789012.dkr.ecr.ap-southeast-2.amazonaws.com/llmops/worker"
    execution_role_arn    = "arn:aws:iam::123456789012:role/llmops-execution"
    api_task_role_arn     = "arn:aws:iam::123456789012:role/llmops-api"
    worker_task_role_arn  = "arn:aws:iam::123456789012:role/llmops-worker"
    bedrock_model_id      = "anthropic.claude-3-haiku-20240307-v1:0"
    artifact_bucket_name  = "llmops-artifacts"
    job_table_name        = "llmops-jobs"
    inference_queue_url   = "https://sqs.ap-southeast-2.amazonaws.com/123456789012/llmops-inference"
    api_secrets = {
      API_AUTH_TOKEN = "arn:aws:secretsmanager:ap-southeast-2:123456789012:secret:llmops-test/api-auth-token-AbCdEf"
    }
  }

  assert {
    condition     = one(aws_ecs_cluster.this.setting).name == "containerInsights" && one(aws_ecs_cluster.this.setting).value == "enabled"
    error_message = "ECS Container Insights must be enabled."
  }

  assert {
    condition     = !one(aws_ecs_service.api.network_configuration).assign_public_ip && !one(aws_ecs_service.worker.network_configuration).assign_public_ip
    error_message = "API and Worker tasks must not receive public IP addresses."
  }

  assert {
    condition     = one(aws_ecs_service.api.deployment_circuit_breaker).enable && one(aws_ecs_service.api.deployment_circuit_breaker).rollback
    error_message = "The API service must automatically roll back failed deployments."
  }

  assert {
    condition     = one(aws_ecs_service.worker.deployment_circuit_breaker).enable && one(aws_ecs_service.worker.deployment_circuit_breaker).rollback
    error_message = "The Worker service must automatically roll back failed deployments."
  }

  assert {
    condition = (
      one([for definition in jsondecode(aws_ecs_task_definition.api.container_definitions) : definition if definition.name == "api"]).readonlyRootFilesystem &&
      one([for definition in jsondecode(aws_ecs_task_definition.worker.container_definitions) : definition if definition.name == "worker"]).readonlyRootFilesystem &&
      one([for definition in jsondecode(aws_ecs_task_definition.api.container_definitions) : definition if definition.name == "api"]).user == "10001:10001" &&
      one([for definition in jsondecode(aws_ecs_task_definition.worker.container_definitions) : definition if definition.name == "worker"]).user == "10001:10001"
    )
    error_message = "Both containers must run non-root with read-only root filesystems."
  }

  assert {
    condition = (
      one(one([for definition in jsondecode(aws_ecs_task_definition.api.container_definitions) : definition if definition.name == "api"]).mountPoints).containerPath == "/tmp" &&
      one(one([for definition in jsondecode(aws_ecs_task_definition.worker.container_definitions) : definition if definition.name == "worker"]).mountPoints).containerPath == "/tmp" &&
      one([for definition in jsondecode(aws_ecs_task_definition.worker.container_definitions) : definition if definition.name == "worker-tmp-permissions"]).command == ["chown", "10001:10001", "/tmp"] &&
      one([for definition in jsondecode(aws_ecs_task_definition.worker.container_definitions) : definition if definition.name == "worker-tmp-permissions"]).user == "0" &&
      !one([for definition in jsondecode(aws_ecs_task_definition.worker.container_definitions) : definition if definition.name == "worker-tmp-permissions"]).essential &&
      one([for dependency in one([for definition in jsondecode(aws_ecs_task_definition.worker.container_definitions) : definition if definition.name == "worker"]).dependsOn : dependency if dependency.containerName == "worker-tmp-permissions"]).condition == "SUCCESS" &&
      !contains(keys(one([for definition in jsondecode(aws_ecs_task_definition.api.container_definitions) : definition if definition.name == "api"]).linuxParameters), "tmpfs") &&
      !contains(keys(one([for definition in jsondecode(aws_ecs_task_definition.worker.container_definitions) : definition if definition.name == "worker"]).linuxParameters), "tmpfs")
    )
    error_message = "Fargate tasks must use supported writable /tmp bind mounts, with Worker ownership initialized before its non-root process starts."
  }

  assert {
    condition = (
      aws_ecs_task_definition.api.task_role_arn != aws_ecs_task_definition.worker.task_role_arn &&
      aws_ecs_task_definition.api.execution_role_arn == aws_ecs_task_definition.worker.execution_role_arn
    )
    error_message = "Runtime roles must remain separate while execution delivery is shared."
  }

  assert {
    condition     = one([for definition in jsondecode(aws_ecs_task_definition.worker.container_definitions) : definition if definition.name == "worker"]).healthCheck.command == ["CMD", "python", "-m", "services.worker.healthcheck"]
    error_message = "ECS must monitor the Worker heartbeat health check."
  }

  assert {
    condition = alltrue([
      for definition in [
        one([for definition in jsondecode(aws_ecs_task_definition.api.container_definitions) : definition if definition.name == "api"]),
        one([for definition in jsondecode(aws_ecs_task_definition.worker.container_definitions) : definition if definition.name == "worker"]),
      ] : one([for value in definition.environment : value.value if value.name == "JOB_BACKEND"]) == "aws"
    ])
    error_message = "Both ECS services must explicitly select the durable AWS job backend."
  }

  assert {
    condition = (
      one(one([for definition in jsondecode(aws_ecs_task_definition.api.container_definitions) : definition if definition.name == "api"]).secrets).name == "API_AUTH_TOKEN" &&
      one(one([for definition in jsondecode(aws_ecs_task_definition.api.container_definitions) : definition if definition.name == "api"]).secrets).valueFrom == "arn:aws:secretsmanager:ap-southeast-2:123456789012:secret:llmops-test/api-auth-token-AbCdEf" &&
      length(one([for definition in jsondecode(aws_ecs_task_definition.worker.container_definitions) : definition if definition.name == "worker"]).secrets) == 0
    )
    error_message = "Only the API task must receive the authentication token through ECS secret injection."
  }

  assert {
    condition = one([
      for value in one([for definition in jsondecode(aws_ecs_task_definition.worker.container_definitions) : definition if definition.name == "worker"]).environment :
      value.value if value.name == "JOB_MAX_RECEIVE_COUNT"
    ]) == "5"
    error_message = "Worker retry accounting must match the SQS redrive policy."
  }

  assert {
    condition = (
      length(jsondecode(aws_ecs_task_definition.api.container_definitions)) == 2 &&
      length(jsondecode(aws_ecs_task_definition.worker.container_definitions)) == 3 &&
      alltrue([
        for definition in [
          jsondecode(aws_ecs_task_definition.api.container_definitions),
          jsondecode(aws_ecs_task_definition.worker.container_definitions),
          ] : (
          one([for container in definition : container if container.name == "aws-otel-collector"]).image == "public.ecr.aws/aws-observability/aws-otel-collector:v0.48.0" &&
          one([for container in definition : container if container.name == "aws-otel-collector"]).essential &&
          one([for container in definition : container if container.name == "aws-otel-collector"]).command == ["--config=/etc/ecs/ecs-default-config.yaml"]
        )
      ])
    )
    error_message = "Every task must run the pinned essential ADOT Collector sidecar."
  }

  assert {
    condition = alltrue([
      for definition in [
        one([for container in jsondecode(aws_ecs_task_definition.api.container_definitions) : container if container.name == "api"]),
        one([for container in jsondecode(aws_ecs_task_definition.worker.container_definitions) : container if container.name == "worker"]),
        ] : (
        one([for value in definition.environment : value.value if value.name == "OTEL_EXPORTER_OTLP_ENDPOINT"]) == "http://127.0.0.1:4317" &&
        one([for dependency in definition.dependsOn : dependency if dependency.containerName == "aws-otel-collector"]).condition == "START"
      )
    ])
    error_message = "Applications must export only to their local collector and start after it."
  }
}

run "ecs_rejects_invalid_fargate_size" {
  command = plan

  module {
    source = "../../modules/ecs"
  }

  variables {
    name                  = "llmops-test"
    environment           = "test"
    aws_region            = "ap-southeast-2"
    vpc_id                = "vpc-0123456789abcdef0"
    private_subnet_ids    = ["subnet-private-a", "subnet-private-b"]
    alb_security_group_id = "sg-0123456789abcdef0"
    api_target_group_arn  = "arn:aws:elasticloadbalancing:ap-southeast-2:123456789012:targetgroup/llmops-api/0000000000000000"
    api_repository_url    = "123456789012.dkr.ecr.ap-southeast-2.amazonaws.com/llmops/api"
    worker_repository_url = "123456789012.dkr.ecr.ap-southeast-2.amazonaws.com/llmops/worker"
    execution_role_arn    = "arn:aws:iam::123456789012:role/llmops-execution"
    api_task_role_arn     = "arn:aws:iam::123456789012:role/llmops-api"
    worker_task_role_arn  = "arn:aws:iam::123456789012:role/llmops-worker"
    bedrock_model_id      = "test-model"
    artifact_bucket_name  = "llmops-artifacts"
    job_table_name        = "llmops-jobs"
    inference_queue_url   = "https://sqs.ap-southeast-2.amazonaws.com/123456789012/llmops-inference"
    api_cpu               = 256
    api_memory            = 4096
  }

  expect_failures = [aws_ecs_task_definition.api]
}

run "monitoring_covers_platform_and_llm_failure_modes" {
  command = apply

  module {
    source = "../../modules/monitoring"
  }

  override_data {
    target = data.aws_partition.current
    values = { partition = "aws" }
  }

  override_data {
    target = data.aws_caller_identity.current
    values = { account_id = "123456789012" }
  }

  override_resource {
    target = aws_kms_key.alarms
    values = {
      arn    = "arn:aws:kms:ap-southeast-2:123456789012:key/00000000-0000-0000-0000-000000000000"
      key_id = "00000000-0000-0000-0000-000000000000"
    }
  }

  override_resource {
    target = aws_sns_topic.alarms
    values = {
      arn = "arn:aws:sns:ap-southeast-2:123456789012:llmops-test-alarms"
    }
  }

  variables {
    name                          = "llmops-test"
    environment                   = "test"
    aws_region                    = "ap-southeast-2"
    cluster_name                  = "llmops-cluster"
    api_service_name              = "llmops-api"
    worker_service_name           = "llmops-worker"
    load_balancer_arn_suffix      = "app/llmops/0000000000000000"
    target_group_arn_suffix       = "targetgroup/llmops/0000000000000000"
    queue_name                    = "llmops-inference"
    dead_letter_queue_name        = "llmops-inference-dlq"
    api_log_group_name            = "/ecs/llmops/api"
    worker_log_group_name         = "/ecs/llmops/worker"
    bedrock_model_id              = "anthropic.test-model"
    waf_enabled                   = true
    waf_web_acl_metric_name       = "llmopsWebAcl"
    notification_emails           = ["platform@example.com"]
    error_rate_threshold_percent  = 5
    budget_notifications_enabled  = true
    llm_hourly_cost_threshold_usd = 10
  }

  assert {
    condition = (
      aws_sns_topic.alarms.kms_master_key_id == aws_kms_key.alarms.arn &&
      aws_kms_key.alarms.enable_key_rotation &&
      aws_kms_key.alarms.deletion_window_in_days == 30
    )
    error_message = "Alarm notifications must use a rotated, recoverably deleted customer KMS key."
  }

  assert {
    condition = (
      strcontains(aws_kms_key.alarms.policy, "cloudwatch.amazonaws.com") &&
      strcontains(aws_kms_key.alarms.policy, "budgets.amazonaws.com") &&
      strcontains(aws_kms_key.alarms.policy, "aws:SourceAccount") &&
      strcontains(aws_sns_topic_policy.alarms.policy, "aws:SourceArn") &&
      strcontains(aws_sns_topic_policy.alarms.policy, "arn:aws:budgets::123456789012:*")
    )
    error_message = "KMS and SNS policies must scope the CloudWatch service integration against confused deputies."
  }

  assert {
    condition = (
      one(aws_cloudwatch_metric_alarm.llm_hourly_cost).threshold == 10 &&
      one(aws_cloudwatch_metric_alarm.llm_hourly_cost).comparison_operator == "GreaterThanThreshold" &&
      one([for query in one(aws_cloudwatch_metric_alarm.llm_hourly_cost).metric_query : query if query.id == "total_cost"]).expression == "api_cost+worker_cost" &&
      toset([for query in one(aws_cloudwatch_metric_alarm.llm_hourly_cost).metric_query : query.id if query.expression == null]) == toset(["api_cost", "worker_cost"])
    )
    error_message = "Hourly LLM cost must combine API and Worker estimates before alerting."
  }

  assert {
    condition     = length(aws_sns_topic_subscription.email) == 1
    error_message = "Every configured notification email must receive a confirmable subscription."
  }

  assert {
    condition = (
      aws_cloudwatch_metric_alarm.alb_error_rate.threshold == 5 &&
      aws_cloudwatch_metric_alarm.alb_error_rate.datapoints_to_alarm == 3 &&
      aws_cloudwatch_metric_alarm.alb_error_rate.treat_missing_data == "notBreaching"
    )
    error_message = "ALB error rate must use a stable 3-of-5 production signal."
  }

  assert {
    condition = (
      length(aws_cloudwatch_metric_alarm.ecs_cpu) == 2 &&
      length(aws_cloudwatch_metric_alarm.ecs_memory) == 2 &&
      alltrue([for alarm in aws_cloudwatch_metric_alarm.ecs_cpu : alarm.treat_missing_data == "breaching"])
    )
    error_message = "Both ECS services need CPU, memory, and missing-telemetry protection."
  }

  assert {
    condition = (
      aws_cloudwatch_metric_alarm.dead_letter_messages.threshold == 0 &&
      aws_cloudwatch_metric_alarm.queue_age.metric_name == "ApproximateAgeOfOldestMessage"
    )
    error_message = "Queue monitoring must detect both stuck and dead-lettered inference jobs."
  }

  assert {
    condition = (
      aws_cloudwatch_metric_alarm.model_error_rate.threshold == 5 &&
      aws_cloudwatch_metric_alarm.llm_p95_latency.extended_statistic == "p95"
    )
    error_message = "LLM-specific error rate and P95 latency SLO alarms are required."
  }

  assert {
    condition = (
      length(jsondecode(aws_cloudwatch_dashboard.this.dashboard_body).widgets) == 6 &&
      alltrue(flatten([
        for widget in jsondecode(aws_cloudwatch_dashboard.this.dashboard_body).widgets :
        widget.type == "metric" ? [for metric in widget.properties.metrics : can(metric[0])] : []
      ])) &&
      strcontains(aws_cloudwatch_dashboard.this.dashboard_body, "RunningTaskCount") &&
      strcontains(aws_cloudwatch_dashboard.this.dashboard_body, "DesiredTaskCount") &&
      strcontains(aws_cloudwatch_dashboard.this.dashboard_body, "BlockedRequests") &&
      strcontains(aws_cloudwatch_dashboard.this.dashboard_body, "llmopsWebAcl")
    )
    error_message = "The operations dashboard must contain all six signal groups and live scaling capacity."
  }

  assert {
    condition = (
      aws_cloudwatch_log_metric_filter.http_requests.metric_transformation[0].name == "HTTPRequestCount" &&
      aws_cloudwatch_log_metric_filter.http_latency.metric_transformation[0].unit == "Milliseconds"
    )
    error_message = "Structured API logs must produce request count and latency metrics."
  }
}

run "monitoring_rejects_unsafe_thresholds" {
  command = plan

  module {
    source = "../../modules/monitoring"
  }

  variables {
    name                                   = "llmops-test"
    environment                            = "test"
    aws_region                             = "ap-southeast-2"
    cluster_name                           = "cluster"
    api_service_name                       = "api"
    worker_service_name                    = "worker"
    load_balancer_arn_suffix               = "app/test/id"
    target_group_arn_suffix                = "targetgroup/test/id"
    queue_name                             = "queue"
    dead_letter_queue_name                 = "queue-dlq"
    api_log_group_name                     = "/ecs/api"
    worker_log_group_name                  = "/ecs/worker"
    bedrock_model_id                       = "model"
    error_rate_threshold_percent           = 101
    p95_latency_threshold_ms               = 0
    queue_age_threshold_seconds            = 30
    resource_utilization_threshold_percent = 0
  }

  expect_failures = [
    var.error_rate_threshold_percent,
    var.p95_latency_threshold_ms,
    var.queue_age_threshold_seconds,
    var.resource_utilization_threshold_percent,
  ]
}

run "rejects_mutable_latest_image_tag" {
  command = plan

  variables {
    availability_zones = ["ap-southeast-2a", "ap-southeast-2b"]
    api_image_tag      = "latest"
  }

  expect_failures = [var.api_image_tag]
}

run "ecs_autoscaling_tracks_api_utilization_and_worker_backlog" {
  command = apply

  module {
    source = "../../modules/autoscaling"
  }

  variables {
    name                           = "llmops-test"
    cluster_name                   = "llmops-test"
    api_service_name               = "llmops-test-api"
    worker_service_name            = "llmops-test-worker"
    queue_name                     = "llmops-test-inference"
    api_min_capacity               = 2
    api_max_capacity               = 8
    worker_min_capacity            = 2
    worker_max_capacity            = 20
    worker_backlog_target_per_task = 3
  }

  assert {
    condition = (
      aws_appautoscaling_target.api.resource_id == "service/llmops-test/llmops-test-api" &&
      aws_appautoscaling_target.api.min_capacity == 2 &&
      aws_appautoscaling_target.api.max_capacity == 8 &&
      aws_appautoscaling_target.worker.resource_id == "service/llmops-test/llmops-test-worker" &&
      aws_appautoscaling_target.worker.min_capacity == 2 &&
      aws_appautoscaling_target.worker.max_capacity == 20
    )
    error_message = "ECS services must retain explicit availability floors and cost ceilings."
  }

  assert {
    condition = (
      one(one(aws_appautoscaling_policy.api_cpu.target_tracking_scaling_policy_configuration).predefined_metric_specification).predefined_metric_type == "ECSServiceAverageCPUUtilization" &&
      one(one(aws_appautoscaling_policy.api_memory.target_tracking_scaling_policy_configuration).predefined_metric_specification).predefined_metric_type == "ECSServiceAverageMemoryUtilization" &&
      one(aws_appautoscaling_policy.api_cpu.target_tracking_scaling_policy_configuration).scale_out_cooldown < one(aws_appautoscaling_policy.api_cpu.target_tracking_scaling_policy_configuration).scale_in_cooldown
    )
    error_message = "API autoscaling must react to CPU and memory while scaling in conservatively."
  }

  assert {
    condition = (
      one([for query in one(one(aws_appautoscaling_policy.worker_backlog.target_tracking_scaling_policy_configuration).customized_metric_specification).metrics : query if query.id == "backlog_per_task"]).expression == "backlog / running" &&
      one(one([for query in one(one(aws_appautoscaling_policy.worker_backlog.target_tracking_scaling_policy_configuration).customized_metric_specification).metrics : query if query.id == "backlog"]).metric_stat).metric[0].namespace == "AWS/SQS" &&
      one(one([for query in one(one(aws_appautoscaling_policy.worker_backlog.target_tracking_scaling_policy_configuration).customized_metric_specification).metrics : query if query.id == "running"]).metric_stat).metric[0].namespace == "ECS/ContainerInsights" &&
      one(aws_appautoscaling_policy.worker_backlog.target_tracking_scaling_policy_configuration).target_value == 3
    )
    error_message = "Worker autoscaling must target SQS backlog per running ECS task."
  }
}

run "autoscaling_rejects_capacity_ceiling_below_floor" {
  command = plan

  module {
    source = "../../modules/autoscaling"
  }

  variables {
    name                = "llmops-test"
    cluster_name        = "llmops-test"
    api_service_name    = "llmops-test-api"
    worker_service_name = "llmops-test-worker"
    queue_name          = "llmops-test-inference"
    api_min_capacity    = 3
    api_max_capacity    = 2
    worker_min_capacity = 2
    worker_max_capacity = 1
  }

  expect_failures = [
    aws_appautoscaling_target.api,
    aws_appautoscaling_target.worker,
  ]
}

run "waf_blocks_managed_threats_and_redacts_security_logs" {
  command = apply

  module {
    source = "../../modules/waf"
  }

  variables {
    name                            = "llmops-test"
    aws_region                      = "ap-southeast-2"
    alb_arn                         = "arn:aws:elasticloadbalancing:ap-southeast-2:123456789012:loadbalancer/app/llmops-test/id"
    rate_limit_per_five_minutes     = 750
    blocked_request_alarm_threshold = 25
    alarm_topic_arn                 = "arn:aws:sns:ap-southeast-2:123456789012:llmops-alerts"
  }

  assert {
    condition = (
      aws_wafv2_web_acl.this["this"].scope == "REGIONAL" &&
      aws_wafv2_web_acl_association.alb["this"].resource_arn == var.alb_arn &&
      aws_wafv2_web_acl_association.alb["this"].web_acl_arn == aws_wafv2_web_acl.this["this"].arn &&
      length(aws_wafv2_web_acl.this["this"].rule) == 4 &&
      !one(aws_wafv2_web_acl.this["this"].visibility_config).sampled_requests_enabled
    )
    error_message = "A regional four-rule Web ACL must protect the ALB without request sampling."
  }

  assert {
    condition = (
      one(one(one([for rule in aws_wafv2_web_acl.this["this"].rule : rule if rule.name == "RateLimitPerSourceIp"]).statement).rate_based_statement).limit == 750 &&
      one(one(one([for rule in aws_wafv2_web_acl.this["this"].rule : rule if rule.name == "RateLimitPerSourceIp"]).statement).rate_based_statement).evaluation_window_sec == 300 &&
      toset(flatten([
        for rule in aws_wafv2_web_acl.this["this"].rule : [
          for statement in rule.statement : [
            for managed in statement.managed_rule_group_statement : managed.name
          ]
        ]
        ])) == toset([
        "AWSManagedRulesAmazonIpReputationList",
        "AWSManagedRulesKnownBadInputsRuleSet",
        "AWSManagedRulesCommonRuleSet",
      ])
    )
    error_message = "WAF must combine per-IP throttling with the three required AWS managed rule groups."
  }

  assert {
    condition = (
      startswith(aws_cloudwatch_log_group.waf["this"].name, "aws-waf-logs-") &&
      strcontains(aws_cloudwatch_log_resource_policy.waf["this"].policy_document, "delivery.logs.amazonaws.com") &&
      strcontains(aws_cloudwatch_log_resource_policy.waf["this"].policy_document, aws_cloudwatch_log_group.waf["this"].arn) &&
      one(aws_wafv2_web_acl_logging_configuration.this["this"].logging_filter).default_behavior == "DROP" &&
      one(one(aws_wafv2_web_acl_logging_configuration.this["this"].logging_filter).filter).behavior == "KEEP" &&
      one(one(one(aws_wafv2_web_acl_logging_configuration.this["this"].logging_filter).filter).condition).action_condition[0].action == "BLOCK" &&
      length(aws_wafv2_web_acl_logging_configuration.this["this"].redacted_fields) == 3 &&
      toset(flatten([
        for field in aws_wafv2_web_acl_logging_configuration.this["this"].redacted_fields : [
          for header in field.single_header : header.name
        ]
      ])) == toset(["authorization", "x-api-key"])
    )
    error_message = "WAF logging must keep blocked traffic only and redact authentication material."
  }

  assert {
    condition = (
      aws_cloudwatch_metric_alarm.blocked_requests["this"].namespace == "AWS/WAFV2" &&
      aws_cloudwatch_metric_alarm.blocked_requests["this"].threshold == 25 &&
      toset(aws_cloudwatch_metric_alarm.blocked_requests["this"].alarm_actions) == toset([var.alarm_topic_arn]) &&
      aws_cloudwatch_metric_alarm.blocked_requests["this"].treat_missing_data == "notBreaching"
    )
    error_message = "Abnormal WAF blocking volume must notify the existing SNS alarm path."
  }
}

run "development_can_disable_paid_waf_boundary" {
  command = plan

  module {
    source = "../../modules/waf"
  }

  variables {
    enabled    = false
    name       = "llmops-test"
    aws_region = "ap-southeast-2"
    alb_arn    = "arn:aws:elasticloadbalancing:ap-southeast-2:123456789012:loadbalancer/app/llmops-test/id"
  }

  assert {
    condition = (
      length(aws_wafv2_web_acl.this) == 0 &&
      length(aws_wafv2_web_acl_association.alb) == 0 &&
      length(aws_wafv2_web_acl_logging_configuration.this) == 0 &&
      length(aws_cloudwatch_log_resource_policy.waf) == 0 &&
      length(aws_cloudwatch_metric_alarm.blocked_requests) == 0
    )
    error_message = "Disabling development WAF must remove the complete paid boundary."
  }
}

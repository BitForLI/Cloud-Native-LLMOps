mock_provider "aws" {}

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
    name                      = "llmops-test"
    api_ecr_repository_arn    = "arn:aws:ecr:ap-southeast-2:123456789012:repository/llmops/api"
    worker_ecr_repository_arn = "arn:aws:ecr:ap-southeast-2:123456789012:repository/llmops/worker"
    artifact_bucket_arn       = "arn:aws:s3:::llmops-artifacts"
    job_table_arn             = "arn:aws:dynamodb:ap-southeast-2:123456789012:table/llmops-jobs"
    inference_queue_arn       = "arn:aws:sqs:ap-southeast-2:123456789012:llmops-inference"
    bedrock_model_ids         = ["anthropic.claude-3-haiku-20240307-v1:0"]
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
    condition = endswith(
      one(one([for statement in jsondecode(local.api_task_policy).Statement : statement if statement.Sid == "InvokeConfiguredModels"]).Resource),
      ":foundation-model/anthropic.claude-3-haiku-20240307-v1:0"
    )
    error_message = "Bedrock invocation must be scoped to the configured model."
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

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
      one(jsondecode(aws_ecs_task_definition.api.container_definitions)).readonlyRootFilesystem &&
      one(jsondecode(aws_ecs_task_definition.worker.container_definitions)).readonlyRootFilesystem &&
      one(jsondecode(aws_ecs_task_definition.api.container_definitions)).user == "10001:10001" &&
      one(jsondecode(aws_ecs_task_definition.worker.container_definitions)).user == "10001:10001"
    )
    error_message = "Both containers must run non-root with read-only root filesystems."
  }

  assert {
    condition = (
      one(one(jsondecode(aws_ecs_task_definition.api.container_definitions)).mountPoints).containerPath == "/tmp" &&
      one(one(jsondecode(aws_ecs_task_definition.worker.container_definitions)).mountPoints).containerPath == "/tmp" &&
      !contains(keys(one(jsondecode(aws_ecs_task_definition.api.container_definitions)).linuxParameters), "tmpfs") &&
      !contains(keys(one(jsondecode(aws_ecs_task_definition.worker.container_definitions)).linuxParameters), "tmpfs")
    )
    error_message = "Fargate tasks must use supported writable /tmp bind mounts, not unsupported tmpfs."
  }

  assert {
    condition = (
      aws_ecs_task_definition.api.task_role_arn != aws_ecs_task_definition.worker.task_role_arn &&
      aws_ecs_task_definition.api.execution_role_arn == aws_ecs_task_definition.worker.execution_role_arn
    )
    error_message = "Runtime roles must remain separate while execution delivery is shared."
  }

  assert {
    condition     = one(jsondecode(aws_ecs_task_definition.worker.container_definitions)).healthCheck.command == ["CMD", "python", "-m", "services.worker.healthcheck"]
    error_message = "ECS must monitor the Worker heartbeat health check."
  }

  assert {
    condition = alltrue([
      for definition in [
        one(jsondecode(aws_ecs_task_definition.api.container_definitions)),
        one(jsondecode(aws_ecs_task_definition.worker.container_definitions)),
      ] : one([for value in definition.environment : value.value if value.name == "JOB_BACKEND"]) == "aws"
    ])
    error_message = "Both ECS services must explicitly select the durable AWS job backend."
  }

  assert {
    condition = one([
      for value in one(jsondecode(aws_ecs_task_definition.worker.container_definitions)).environment :
      value.value if value.name == "JOB_MAX_RECEIVE_COUNT"
    ]) == "5"
    error_message = "Worker retry accounting must match the SQS redrive policy."
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
    name                         = "llmops-test"
    environment                  = "test"
    aws_region                   = "ap-southeast-2"
    cluster_name                 = "llmops-cluster"
    api_service_name             = "llmops-api"
    worker_service_name          = "llmops-worker"
    load_balancer_arn_suffix     = "app/llmops/0000000000000000"
    target_group_arn_suffix      = "targetgroup/llmops/0000000000000000"
    queue_name                   = "llmops-inference"
    dead_letter_queue_name       = "llmops-inference-dlq"
    api_log_group_name           = "/ecs/llmops/api"
    worker_log_group_name        = "/ecs/llmops/worker"
    bedrock_model_id             = "anthropic.test-model"
    notification_emails          = ["platform@example.com"]
    error_rate_threshold_percent = 5
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
      strcontains(aws_kms_key.alarms.policy, "aws:SourceAccount") &&
      strcontains(aws_sns_topic_policy.alarms.policy, "aws:SourceArn")
    )
    error_message = "KMS and SNS policies must scope the CloudWatch service integration against confused deputies."
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
    condition     = length(jsondecode(aws_cloudwatch_dashboard.this.dashboard_body).widgets) == 6
    error_message = "The operations dashboard must contain all six platform signal groups."
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

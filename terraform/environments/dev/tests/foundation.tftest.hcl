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

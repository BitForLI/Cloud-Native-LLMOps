locals {
  common_tags = merge(var.tags, { Component = "queue" })
}

resource "aws_sqs_queue" "dead_letter" {
  name                      = "${var.name}-inference-dlq"
  message_retention_seconds = var.dead_letter_retention_seconds

  sqs_managed_sse_enabled           = var.kms_key_arn == null
  kms_master_key_id                 = var.kms_key_arn
  kms_data_key_reuse_period_seconds = var.kms_key_arn == null ? null : var.kms_data_key_reuse_period_seconds

  tags = merge(local.common_tags, { Name = "${var.name}-inference-dlq" })
}

resource "aws_sqs_queue" "inference" {
  name                       = "${var.name}-inference"
  delay_seconds              = 0
  max_message_size           = var.max_message_size_bytes
  message_retention_seconds  = var.message_retention_seconds
  receive_wait_time_seconds  = var.receive_wait_time_seconds
  visibility_timeout_seconds = var.visibility_timeout_seconds

  sqs_managed_sse_enabled           = var.kms_key_arn == null
  kms_master_key_id                 = var.kms_key_arn
  kms_data_key_reuse_period_seconds = var.kms_key_arn == null ? null : var.kms_data_key_reuse_period_seconds

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dead_letter.arn
    maxReceiveCount     = var.max_receive_count
  })

  tags = merge(local.common_tags, { Name = "${var.name}-inference" })
}

resource "aws_sqs_queue_redrive_allow_policy" "dead_letter" {
  queue_url = aws_sqs_queue.dead_letter.id

  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.inference.arn]
  })
}

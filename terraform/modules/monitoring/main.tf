locals {
  common_tags      = merge(var.tags, { Component = "monitoring" })
  metric_namespace = "CloudNativeLLMOps"
  alarm_actions    = [aws_sns_topic.alarms.arn]
  alarm_topic_arn  = "arn:${data.aws_partition.current.partition}:sns:${var.aws_region}:${data.aws_caller_identity.current.account_id}:${var.name}-alarms"
  ecs_services = {
    api    = var.api_service_name
    worker = var.worker_service_name
  }
  alarm_key_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableAccountAdministration", Effect = "Allow", Action = "kms:*", Resource = "*"
        Principal = { AWS = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root" }
      },
      {
        Sid       = "AllowCloudWatchAlarmEncryption", Effect = "Allow", Resource = "*"
        Principal = { Service = "cloudwatch.amazonaws.com" }
        Action    = ["kms:Decrypt", "kms:GenerateDataKey*"]
        Condition = {
          StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
          ArnLike      = { "aws:SourceArn" = "arn:${data.aws_partition.current.partition}:cloudwatch:${var.aws_region}:${data.aws_caller_identity.current.account_id}:alarm:${var.name}-*" }
        }
      },
      {
        Sid       = "AllowSNSDelivery", Effect = "Allow", Resource = "*"
        Principal = { Service = "sns.amazonaws.com" }
        Action    = ["kms:Decrypt", "kms:GenerateDataKey*"]
        Condition = {
          StringEquals = {
            "aws:SourceAccount"                      = data.aws_caller_identity.current.account_id
            "kms:EncryptionContext:aws:sns:topicArn" = local.alarm_topic_arn
          }
        }
      },
    ]
  })
}

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

resource "aws_kms_key" "alarms" {
  description             = "Encrypts ${var.name} operational alarm notifications"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  policy                  = local.alarm_key_policy
  tags                    = local.common_tags
}

resource "aws_kms_alias" "alarms" {
  name          = "alias/${var.name}-alarms"
  target_key_id = aws_kms_key.alarms.key_id
}

resource "aws_sns_topic" "alarms" {
  name              = "${var.name}-alarms"
  kms_master_key_id = aws_kms_key.alarms.arn
  tags              = local.common_tags
}

resource "aws_sns_topic_policy" "alarms" {
  arn = aws_sns_topic.alarms.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AccountAdministration", Effect = "Allow", Resource = aws_sns_topic.alarms.arn
        Principal = { AWS = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = ["sns:GetTopicAttributes", "sns:SetTopicAttributes", "sns:AddPermission", "sns:RemovePermission", "sns:DeleteTopic", "sns:Subscribe", "sns:ListSubscriptionsByTopic", "sns:Publish"]
      },
      {
        Sid       = "AllowScopedCloudWatchAlarms", Effect = "Allow", Action = "sns:Publish", Resource = aws_sns_topic.alarms.arn
        Principal = { Service = "cloudwatch.amazonaws.com" }
        Condition = {
          StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
          ArnLike      = { "aws:SourceArn" = "arn:${data.aws_partition.current.partition}:cloudwatch:${var.aws_region}:${data.aws_caller_identity.current.account_id}:alarm:${var.name}-*" }
        }
      },
    ]
  })
}

resource "aws_sns_topic_subscription" "email" {
  for_each = var.notification_emails

  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = each.value
}

resource "aws_cloudwatch_log_metric_filter" "http_requests" {
  name           = "${var.name}-http-requests"
  log_group_name = var.api_log_group_name
  pattern        = "{ $.event = \"http_request_completed\" }"

  metric_transformation {
    name          = "HTTPRequestCount"
    namespace     = local.metric_namespace
    value         = "1"
    default_value = 0
    unit          = "Count"
  }
}

resource "aws_cloudwatch_log_metric_filter" "http_server_errors" {
  name           = "${var.name}-http-server-errors"
  log_group_name = var.api_log_group_name
  pattern        = "{ ($.event = \"http_request_completed\") && ($.status_code >= 500) }"

  metric_transformation {
    name          = "HTTPServerErrorCount"
    namespace     = local.metric_namespace
    value         = "1"
    default_value = 0
    unit          = "Count"
  }
}

resource "aws_cloudwatch_log_metric_filter" "http_latency" {
  name           = "${var.name}-http-latency"
  log_group_name = var.api_log_group_name
  pattern        = "{ ($.event = \"http_request_completed\") && ($.latency_ms = *) }"

  metric_transformation {
    name      = "HTTPResponseLatencyMs"
    namespace = local.metric_namespace
    value     = "$.latency_ms"
    unit      = "Milliseconds"
  }
}

resource "aws_cloudwatch_metric_alarm" "alb_error_rate" {
  alarm_name          = "${var.name}-alb-5xx-rate"
  alarm_description   = "API target 5xx rate exceeded ${var.error_rate_threshold_percent} percent."
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.error_rate_threshold_percent
  evaluation_periods  = 5
  datapoints_to_alarm = 3
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
  tags                = local.common_tags

  metric_query {
    id          = "error_rate"
    expression  = "IF(requests>0,100*errors/requests,0)"
    label       = "Target 5xx rate (%)"
    return_data = true
  }

  metric_query {
    id          = "requests"
    return_data = false
    metric {
      metric_name = "RequestCount"
      namespace   = "AWS/ApplicationELB"
      period      = 60
      stat        = "Sum"
      dimensions = {
        LoadBalancer = var.load_balancer_arn_suffix
        TargetGroup  = var.target_group_arn_suffix
      }
    }
  }

  metric_query {
    id          = "errors"
    return_data = false
    metric {
      metric_name = "HTTPCode_Target_5XX_Count"
      namespace   = "AWS/ApplicationELB"
      period      = 60
      stat        = "Sum"
      dimensions = {
        LoadBalancer = var.load_balancer_arn_suffix
        TargetGroup  = var.target_group_arn_suffix
      }
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "alb_p95_latency" {
  alarm_name          = "${var.name}-alb-p95-latency"
  alarm_description   = "API target P95 latency exceeded the production SLO."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  dimensions          = { LoadBalancer = var.load_balancer_arn_suffix, TargetGroup = var.target_group_arn_suffix }
  extended_statistic  = "p95"
  period              = 60
  evaluation_periods  = 5
  datapoints_to_alarm = 3
  threshold           = var.p95_latency_threshold_ms / 1000
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
  tags                = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "alb_alternate_error_rate" {
  count = var.monitor_alternate_target_group ? 1 : 0

  alarm_name          = "${var.name}-alb-alt-5xx-rate"
  alarm_description   = "Alternate API target 5xx rate exceeded ${var.error_rate_threshold_percent} percent."
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.error_rate_threshold_percent
  evaluation_periods  = 5
  datapoints_to_alarm = 3
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
  tags                = local.common_tags

  lifecycle {
    precondition {
      condition     = var.alternate_target_group_arn_suffix != null
      error_message = "alternate_target_group_arn_suffix is required when alternate monitoring is enabled."
    }
  }

  metric_query {
    id          = "error_rate"
    expression  = "IF(requests>0,100*errors/requests,0)"
    label       = "Alternate target 5xx rate (%)"
    return_data = true
  }

  metric_query {
    id          = "requests"
    return_data = false
    metric {
      metric_name = "RequestCount"
      namespace   = "AWS/ApplicationELB"
      period      = 60
      stat        = "Sum"
      dimensions = {
        LoadBalancer = var.load_balancer_arn_suffix
        TargetGroup  = var.alternate_target_group_arn_suffix
      }
    }
  }

  metric_query {
    id          = "errors"
    return_data = false
    metric {
      metric_name = "HTTPCode_Target_5XX_Count"
      namespace   = "AWS/ApplicationELB"
      period      = 60
      stat        = "Sum"
      dimensions = {
        LoadBalancer = var.load_balancer_arn_suffix
        TargetGroup  = var.alternate_target_group_arn_suffix
      }
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "alb_alternate_p95_latency" {
  count = var.monitor_alternate_target_group ? 1 : 0

  alarm_name          = "${var.name}-alb-alt-p95-latency"
  alarm_description   = "Alternate API target P95 latency exceeded the production SLO."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  dimensions          = { LoadBalancer = var.load_balancer_arn_suffix, TargetGroup = var.alternate_target_group_arn_suffix }
  extended_statistic  = "p95"
  period              = 60
  evaluation_periods  = 5
  datapoints_to_alarm = 3
  threshold           = var.p95_latency_threshold_ms / 1000
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
  tags                = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "ecs_cpu" {
  for_each = local.ecs_services

  alarm_name          = "${var.name}-${each.key}-cpu-high"
  alarm_description   = "${each.key} ECS CPU utilization is sustained above threshold."
  namespace           = "AWS/ECS"
  metric_name         = "CPUUtilization"
  dimensions          = { ClusterName = var.cluster_name, ServiceName = each.value }
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 5
  datapoints_to_alarm = 3
  threshold           = var.resource_utilization_threshold_percent
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
  tags                = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "ecs_memory" {
  for_each = local.ecs_services

  alarm_name          = "${var.name}-${each.key}-memory-high"
  alarm_description   = "${each.key} ECS memory utilization is sustained above threshold."
  namespace           = "AWS/ECS"
  metric_name         = "MemoryUtilization"
  dimensions          = { ClusterName = var.cluster_name, ServiceName = each.value }
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 5
  datapoints_to_alarm = 3
  threshold           = var.resource_utilization_threshold_percent
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
  tags                = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "queue_age" {
  alarm_name          = "${var.name}-inference-queue-age"
  alarm_description   = "Inference work has waited too long without completing."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateAgeOfOldestMessage"
  dimensions          = { QueueName = var.queue_name }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  datapoints_to_alarm = 2
  threshold           = var.queue_age_threshold_seconds
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
  tags                = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "dead_letter_messages" {
  alarm_name          = "${var.name}-dead-letter-messages"
  alarm_description   = "At least one inference job reached the dead-letter queue."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = var.dead_letter_queue_name }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
  tags                = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "model_error_rate" {
  alarm_name          = "${var.name}-model-error-rate"
  alarm_description   = "Combined API and Worker model error rate exceeded threshold."
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.error_rate_threshold_percent
  evaluation_periods  = 5
  datapoints_to_alarm = 3
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
  tags                = local.common_tags

  metric_query {
    id          = "rate"
    expression  = "IF(api_requests+worker_requests>0,100*(api_errors+worker_errors)/(api_requests+worker_requests),0)"
    label       = "Model error rate (%)"
    return_data = true
  }

  dynamic "metric_query" {
    for_each = {
      api_requests    = ["LLMRequestCount", "api"]
      api_errors      = ["ModelErrorCount", "api"]
      worker_requests = ["LLMRequestCount", "worker"]
      worker_errors   = ["ModelErrorCount", "worker"]
    }
    content {
      id          = metric_query.key
      return_data = false
      metric {
        metric_name = metric_query.value[0]
        namespace   = local.metric_namespace
        period      = 60
        stat        = "Sum"
        dimensions = {
          Environment = var.environment
          Service     = metric_query.value[1]
          Model       = var.bedrock_model_id
        }
      }
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "llm_p95_latency" {
  alarm_name          = "${var.name}-worker-llm-p95-latency"
  alarm_description   = "Worker Bedrock P95 latency exceeded the production SLO."
  namespace           = local.metric_namespace
  metric_name         = "LLMLatencyMs"
  dimensions          = { Environment = var.environment, Service = "worker", Model = var.bedrock_model_id }
  extended_statistic  = "p95"
  period              = 60
  evaluation_periods  = 5
  datapoints_to_alarm = 3
  threshold           = var.p95_latency_threshold_ms
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
  tags                = local.common_tags
}

resource "aws_cloudwatch_dashboard" "this" {
  dashboard_name = "${var.name}-operations"
  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6
        properties = {
          title = "API traffic and target errors", region = var.aws_region, view = "timeSeries", period = 60
          metrics = concat(
            [
              ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", var.load_balancer_arn_suffix, "TargetGroup", var.target_group_arn_suffix, { stat = "Sum" }],
              [".", "HTTPCode_Target_5XX_Count", ".", ".", ".", ".", { stat = "Sum" }],
            ],
            var.waf_enabled ? [
              ["AWS/WAFV2", "BlockedRequests", "Region", var.aws_region, "Rule", "ALL", "WebACL", var.waf_web_acl_metric_name, { stat = "Sum", label = "WAF blocked" }],
            ] : []
          )
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6
        properties = {
          title = "API and LLM P50/P95 latency", region = var.aws_region, view = "timeSeries", period = 60
          metrics = [
            [local.metric_namespace, "HTTPResponseLatencyMs", { stat = "p50", label = "HTTP p50" }],
            [".", ".", { stat = "p95", label = "HTTP p95" }],
            [local.metric_namespace, "LLMLatencyMs", "Environment", var.environment, "Service", "worker", "Model", var.bedrock_model_id, { stat = "p50", label = "LLM p50" }],
            [".", ".", ".", ".", ".", ".", ".", ".", { stat = "p95", label = "LLM p95" }],
          ]
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 12, height = 6
        properties = {
          title = "ECS CPU and memory", region = var.aws_region, view = "timeSeries", period = 60
          metrics = concat(
            flatten([
              for component, service in local.ecs_services : [
                ["AWS/ECS", "CPUUtilization", "ClusterName", var.cluster_name, "ServiceName", service, { label = "${component} CPU" }],
                [".", "MemoryUtilization", ".", ".", ".", ".", { label = "${component} memory" }],
              ]
            ]),
            flatten([
              for component, service in local.ecs_services : [
                ["ECS/ContainerInsights", "RunningTaskCount", "ClusterName", var.cluster_name, "ServiceName", service, { label = "${component} running", yAxis = "right" }],
                [".", "DesiredTaskCount", ".", ".", ".", ".", { label = "${component} desired", yAxis = "right" }],
              ]
            ])
          )
        }
      },
      {
        type = "metric", x = 12, y = 6, width = 12, height = 6
        properties = {
          title = "Inference queue and DLQ", region = var.aws_region, view = "timeSeries", period = 60
          metrics = [
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", var.queue_name, { label = "Pending" }],
            [".", "ApproximateAgeOfOldestMessage", ".", ".", { label = "Oldest age" }],
            [".", "ApproximateNumberOfMessagesVisible", ".", var.dead_letter_queue_name, { label = "DLQ" }],
          ]
        }
      },
      {
        type = "metric", x = 0, y = 12, width = 12, height = 6
        properties = {
          title = "LLM tokens, errors, and estimated cost", region = var.aws_region, view = "timeSeries", period = 300
          metrics = [
            [local.metric_namespace, "InputTokens", "Environment", var.environment, "Service", "worker", "Model", var.bedrock_model_id, { stat = "Sum" }],
            [".", "OutputTokens", ".", ".", ".", ".", ".", ".", { stat = "Sum" }],
            [".", "ModelErrorCount", ".", ".", ".", ".", ".", ".", { stat = "Sum" }],
            [".", "EstimatedCostUSD", ".", ".", ".", ".", ".", ".", { stat = "Sum", yAxis = "right" }],
          ]
        }
      },
      {
        type = "log", x = 12, y = 12, width = 12, height = 6
        properties = {
          title = "Recent service errors", region = var.aws_region, view = "table"
          query = "SOURCE '${var.api_log_group_name}' | SOURCE '${var.worker_log_group_name}' | fields @timestamp, @logStream, level, message, error_type | filter level in ['ERROR', 'CRITICAL'] | sort @timestamp desc | limit 50"
        }
      },
    ]
  })

  lifecycle {
    precondition {
      condition     = !var.waf_enabled || var.waf_web_acl_metric_name != null
      error_message = "waf_web_acl_metric_name is required when waf_enabled is true."
    }
  }
}

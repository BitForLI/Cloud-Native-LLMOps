locals {
  resources   = var.enabled ? { this = true } : {}
  metric_name = replace(var.name, "-", "")
  common_tags = merge(var.tags, { Component = "edge-security" })
  partition   = split(":", var.alb_arn)[1]
  account_id  = split(":", var.alb_arn)[4]
  alarm_actions = var.alarm_topic_arn == null ? [] : [
    var.alarm_topic_arn,
  ]
}

resource "aws_cloudwatch_log_group" "waf" {
  for_each = local.resources

  name              = "aws-waf-logs-${var.name}"
  retention_in_days = var.log_retention_days

  tags = merge(local.common_tags, { Name = "aws-waf-logs-${var.name}" })
}

resource "aws_wafv2_web_acl" "this" {
  for_each = local.resources

  name        = "${var.name}-regional"
  description = "Layer 7 protection for the ${var.name} public ALB"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  rule {
    name     = "RateLimitPerSourceIp"
    priority = 0

    action {
      block {}
    }

    statement {
      rate_based_statement {
        aggregate_key_type    = "IP"
        evaluation_window_sec = 300
        limit                 = var.rate_limit_per_five_minutes
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.metric_name}RateLimit"
      sampled_requests_enabled   = false
    }
  }

  rule {
    name     = "AmazonIpReputation"
    priority = 10

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesAmazonIpReputationList"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.metric_name}IpReputation"
      sampled_requests_enabled   = false
    }
  }

  rule {
    name     = "KnownBadInputs"
    priority = 20

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.metric_name}KnownBadInputs"
      sampled_requests_enabled   = false
    }
  }

  rule {
    name     = "CommonThreats"
    priority = 30

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.metric_name}CommonThreats"
      sampled_requests_enabled   = false
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.metric_name}WebAcl"
    sampled_requests_enabled   = false
  }

  tags = merge(local.common_tags, { Name = "${var.name}-regional" })
}

resource "aws_wafv2_web_acl_association" "alb" {
  for_each = local.resources

  resource_arn = var.alb_arn
  web_acl_arn  = aws_wafv2_web_acl.this[each.key].arn
}

resource "aws_cloudwatch_log_resource_policy" "waf" {
  for_each = local.resources

  policy_name = "${var.name}-waf-log-delivery"
  policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowAwsWafLogDelivery"
      Effect = "Allow"
      Principal = {
        Service = "delivery.logs.amazonaws.com"
      }
      Action = [
        "logs:CreateLogStream",
        "logs:PutLogEvents",
      ]
      Resource = ["${aws_cloudwatch_log_group.waf[each.key].arn}:*"]
      Condition = {
        ArnLike = {
          "aws:SourceArn" = "arn:${local.partition}:logs:${var.aws_region}:${local.account_id}:*"
        }
        StringEquals = {
          "aws:SourceAccount" = local.account_id
        }
      }
    }]
  })
}

resource "aws_wafv2_web_acl_logging_configuration" "this" {
  for_each = local.resources

  log_destination_configs = [aws_cloudwatch_log_group.waf[each.key].arn]
  resource_arn            = aws_wafv2_web_acl.this[each.key].arn

  logging_filter {
    default_behavior = "DROP"

    filter {
      behavior    = "KEEP"
      requirement = "MEETS_ANY"

      condition {
        action_condition {
          action = "BLOCK"
        }
      }
    }
  }

  redacted_fields {
    query_string {}
  }

  redacted_fields {
    single_header {
      name = "authorization"
    }
  }

  redacted_fields {
    single_header {
      name = "x-api-key"
    }
  }

  depends_on = [aws_cloudwatch_log_resource_policy.waf]
}

resource "aws_cloudwatch_metric_alarm" "blocked_requests" {
  for_each = local.resources

  alarm_name        = "${var.name}-waf-blocked-requests"
  alarm_description = "AWS WAF blocked an abnormal volume of public API traffic."
  namespace         = "AWS/WAFV2"
  metric_name       = "BlockedRequests"
  dimensions = {
    Region = var.aws_region
    Rule   = "ALL"
    WebACL = "${local.metric_name}WebAcl"
  }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold           = var.blocked_request_alarm_threshold
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  tags = local.common_tags
}

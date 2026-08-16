output "enabled" {
  description = "Whether the regional WAF boundary is enabled."
  value       = var.enabled
}

output "web_acl_arn" {
  description = "Regional Web ACL ARN, or null when disabled."
  value       = try(aws_wafv2_web_acl.this["this"].arn, null)
}

output "web_acl_metric_name" {
  description = "CloudWatch Web ACL metric dimension, or null when disabled."
  value       = var.enabled ? "${local.metric_name}WebAcl" : null
}

output "log_group_name" {
  description = "Blocked-request WAF log group, or null when disabled."
  value       = try(aws_cloudwatch_log_group.waf["this"].name, null)
}

output "blocked_request_alarm_name" {
  description = "Security alarm name, or null when disabled."
  value       = try(aws_cloudwatch_metric_alarm.blocked_requests["this"].alarm_name, null)
}

output "rate_limit_per_five_minutes" {
  description = "Configured per-source-IP five-minute request ceiling."
  value       = var.rate_limit_per_five_minutes
}

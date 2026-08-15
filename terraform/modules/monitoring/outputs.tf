output "dashboard_name" {
  description = "CloudWatch operations dashboard name."
  value       = aws_cloudwatch_dashboard.this.dashboard_name
}

output "alarm_topic_arn" {
  description = "Encrypted SNS topic receiving alarm and recovery notifications."
  value       = aws_sns_topic.alarms.arn
}

output "alarm_names" {
  description = "CloudWatch alarms managed by this module."
  value = concat(
    [
      aws_cloudwatch_metric_alarm.alb_error_rate.alarm_name,
      aws_cloudwatch_metric_alarm.alb_p95_latency.alarm_name,
      aws_cloudwatch_metric_alarm.queue_age.alarm_name,
      aws_cloudwatch_metric_alarm.dead_letter_messages.alarm_name,
      aws_cloudwatch_metric_alarm.model_error_rate.alarm_name,
      aws_cloudwatch_metric_alarm.llm_p95_latency.alarm_name,
    ],
    values(aws_cloudwatch_metric_alarm.ecs_cpu)[*].alarm_name,
    values(aws_cloudwatch_metric_alarm.ecs_memory)[*].alarm_name,
  )
}

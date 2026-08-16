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
    aws_cloudwatch_metric_alarm.alb_alternate_error_rate[*].alarm_name,
    aws_cloudwatch_metric_alarm.alb_alternate_p95_latency[*].alarm_name,
    aws_cloudwatch_metric_alarm.evaluation_gate[*].alarm_name,
    aws_cloudwatch_metric_alarm.evaluation_absent[*].alarm_name,
    aws_cloudwatch_metric_alarm.evaluation_accuracy[*].alarm_name,
    aws_cloudwatch_metric_alarm.llm_hourly_cost[*].alarm_name,
  )
}

output "llm_cost_alarm_name" {
  description = "Hourly estimated LLM cost alarm name when configured."
  value       = try(aws_cloudwatch_metric_alarm.llm_hourly_cost[0].alarm_name, null)
}

output "evaluation_alarm_names" {
  description = "Continuous evaluation failure, absence, and accuracy alarms."
  value = concat(
    aws_cloudwatch_metric_alarm.evaluation_gate[*].alarm_name,
    aws_cloudwatch_metric_alarm.evaluation_absent[*].alarm_name,
    aws_cloudwatch_metric_alarm.evaluation_accuracy[*].alarm_name,
  )
}

output "deployment_alarm_names" {
  description = "Focused alarm sets consumed by deployment controllers."
  value = {
    api = concat(
      [
        aws_cloudwatch_metric_alarm.alb_error_rate.alarm_name,
        aws_cloudwatch_metric_alarm.alb_p95_latency.alarm_name,
        aws_cloudwatch_metric_alarm.ecs_cpu["api"].alarm_name,
        aws_cloudwatch_metric_alarm.ecs_memory["api"].alarm_name,
        aws_cloudwatch_metric_alarm.model_error_rate.alarm_name,
      ],
      aws_cloudwatch_metric_alarm.alb_alternate_error_rate[*].alarm_name,
      aws_cloudwatch_metric_alarm.alb_alternate_p95_latency[*].alarm_name,
    )
    worker = [
      aws_cloudwatch_metric_alarm.ecs_cpu["worker"].alarm_name,
      aws_cloudwatch_metric_alarm.ecs_memory["worker"].alarm_name,
      aws_cloudwatch_metric_alarm.queue_age.alarm_name,
      aws_cloudwatch_metric_alarm.dead_letter_messages.alarm_name,
      aws_cloudwatch_metric_alarm.model_error_rate.alarm_name,
      aws_cloudwatch_metric_alarm.llm_p95_latency.alarm_name,
    ]
  }
}

output "trail_name" {
  description = "Multi-Region management trail name."
  value       = aws_cloudtrail.management.name
}

output "archive_bucket_name" {
  description = "Private versioned S3 bucket containing validated audit archives."
  value       = aws_s3_bucket.audit.id
}

output "log_group_name" {
  description = "CloudWatch Logs group used for near-real-time detections."
  value       = aws_cloudwatch_log_group.audit.name
}

output "security_alarm_names" {
  description = "Security detection alarm names."
  value       = sort(values(aws_cloudwatch_metric_alarm.security)[*].alarm_name)
}

output "log_file_validation_enabled" {
  description = "Whether CloudTrail digest validation is enabled."
  value       = aws_cloudtrail.management.enable_log_file_validation
}

output "artifact_bucket_arn" {
  description = "ARN of the private artifact bucket."
  value       = aws_s3_bucket.artifacts.arn
}

output "artifact_bucket_name" {
  description = "Globally unique name of the private artifact bucket."
  value       = aws_s3_bucket.artifacts.id
}

output "job_table_arn" {
  description = "ARN of the DynamoDB job table."
  value       = aws_dynamodb_table.jobs.arn
}

output "job_table_name" {
  description = "Name of the DynamoDB job table."
  value       = aws_dynamodb_table.jobs.name
}

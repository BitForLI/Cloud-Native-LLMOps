output "vpc_id" {
  description = "Development VPC ID."
  value       = module.networking.vpc_id
}

output "public_subnet_ids" {
  description = "Public subnets reserved for the ALB."
  value       = module.networking.public_subnet_ids
}

output "private_subnet_ids" {
  description = "Private subnets reserved for ECS tasks."
  value       = module.networking.private_subnet_ids
}

output "availability_zones" {
  description = "Availability zones used by the development network."
  value       = module.networking.availability_zones
}

output "nat_gateway_ids" {
  description = "NAT gateway IDs keyed by availability zone."
  value       = module.networking.nat_gateway_ids
}

output "ecr_repository_urls" {
  description = "Image destinations keyed by service."
  value = {
    api    = module.api_ecr.repository_url
    worker = module.worker_ecr.repository_url
  }
}

output "artifact_bucket_name" {
  description = "Private S3 bucket for evaluation and inference artifacts."
  value       = module.database.artifact_bucket_name
}

output "job_table_name" {
  description = "DynamoDB table used for durable job state."
  value       = module.database.job_table_name
}

output "inference_queue_url" {
  description = "SQS queue URL consumed by the API and Worker."
  value       = module.queue.queue_url
}

output "inference_dead_letter_queue_url" {
  description = "SQS DLQ URL used for failed-job inspection and redrive."
  value       = module.queue.dead_letter_queue_url
}

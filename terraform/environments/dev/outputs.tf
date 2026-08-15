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

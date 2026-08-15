output "load_balancer_arn" {
  description = "ARN of the application load balancer."
  value       = aws_lb.this.arn
}

output "load_balancer_arn_suffix" {
  description = "CloudWatch LoadBalancer dimension value."
  value       = aws_lb.this.arn_suffix
}

output "load_balancer_dns_name" {
  description = "DNS name used to reach the API."
  value       = aws_lb.this.dns_name
}

output "load_balancer_zone_id" {
  description = "Route 53 hosted zone ID for an alias record."
  value       = aws_lb.this.zone_id
}

output "deletion_protection_enabled" {
  description = "Whether accidental ALB deletion is blocked."
  value       = aws_lb.this.enable_deletion_protection
}

output "security_group_id" {
  description = "ALB security group accepted by the ECS task ingress rule."
  value       = aws_security_group.alb.id
}

output "api_target_group_arn" {
  description = "Target group ARN attached to the API service."
  value       = aws_lb_target_group.api.arn
}

output "api_target_group_arn_suffix" {
  description = "CloudWatch TargetGroup dimension value."
  value       = aws_lb_target_group.api.arn_suffix
}

output "api_target_group_name" {
  description = "Primary API target group name."
  value       = aws_lb_target_group.api.name
}

output "api_alternate_target_group_arn" {
  description = "Alternate API target group ARN for blue/green deployment."
  value       = try(aws_lb_target_group.api_alternate[0].arn, null)
}

output "api_alternate_target_group_arn_suffix" {
  description = "Alternate target group CloudWatch dimension for release alarms."
  value       = try(aws_lb_target_group.api_alternate[0].arn_suffix, null)
}

output "api_alternate_target_group_name" {
  description = "Alternate API target group name for blue/green deployment."
  value       = try(aws_lb_target_group.api_alternate[0].name, null)
}

output "blue_green_enabled" {
  description = "Whether an alternate API target group is provisioned."
  value       = var.enable_blue_green
}

output "api_listener_arn" {
  description = "HTTPS listener ARN when configured, otherwise the HTTP listener ARN."
  value = var.certificate_arn == null ? (
    aws_lb_listener.http_forward[0].arn
  ) : aws_lb_listener.https[0].arn
}

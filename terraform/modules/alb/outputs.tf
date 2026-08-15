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

output "api_listener_arn" {
  description = "HTTPS listener ARN when configured, otherwise the HTTP listener ARN."
  value = var.certificate_arn == null ? (
    aws_lb_listener.http_forward[0].arn
  ) : aws_lb_listener.https[0].arn
}

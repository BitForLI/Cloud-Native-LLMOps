output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "CIDR assigned to the VPC."
  value       = aws_vpc.this.cidr_block
}

output "availability_zones" {
  description = "Ordered availability zones used by the subnet tiers."
  value       = local.availability_zones
}

output "public_subnet_ids" {
  description = "Ordered public subnet IDs for internet-facing load balancers."
  value       = [for zone in local.availability_zones : aws_subnet.public[zone].id]
}

output "private_subnet_ids" {
  description = "Ordered private subnet IDs for ECS tasks and data services."
  value       = [for zone in local.availability_zones : aws_subnet.private[zone].id]
}

output "private_route_table_ids" {
  description = "Ordered private route table IDs."
  value       = [for zone in local.availability_zones : aws_route_table.private[zone].id]
}

output "nat_gateway_ids" {
  description = "NAT gateway IDs keyed by availability zone; empty in none mode."
  value       = { for zone, gateway in aws_nat_gateway.this : zone => gateway.id }
}

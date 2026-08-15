locals {
  name = "${var.project_name}-${var.environment}"
  common_tags = {
    Environment = var.environment
    ManagedBy   = "terraform"
    Project     = var.project_name
  }
}

module "networking" {
  source = "../../modules/networking"

  name                    = local.name
  vpc_cidr                = var.vpc_cidr
  availability_zone_count = var.availability_zone_count
  availability_zones      = var.availability_zones
  nat_gateway_mode        = var.nat_gateway_mode
  tags                    = local.common_tags
}

module "api_ecr" {
  source = "../../modules/ecr"

  name = "${var.project_name}/${var.environment}/api"
  tags = local.common_tags
}

module "worker_ecr" {
  source = "../../modules/ecr"

  name = "${var.project_name}/${var.environment}/worker"
  tags = local.common_tags
}

variable "aws_region" {
  description = "AWS region in which the development stack is created."
  type        = string
  default     = "ap-southeast-2"
}

variable "project_name" {
  description = "Lowercase project identifier used in names and tags."
  type        = string
  default     = "cloud-native-llmops"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,25}[a-z0-9]$", var.project_name))
    error_message = "project_name must be 3-27 lowercase alphanumeric or hyphen characters."
  }
}

variable "environment" {
  description = "Deployment environment name."
  type        = string
  default     = "dev"

  validation {
    condition     = var.environment == "dev"
    error_message = "This root module is reserved for the dev environment."
  }
}

variable "vpc_cidr" {
  description = "CIDR for the development VPC."
  type        = string
  default     = "10.20.0.0/16"

  validation {
    condition = can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}/[0-9]{1,2}$", var.vpc_cidr)) && try(
      tonumber(split("/", var.vpc_cidr)[1]) >= 16 &&
      tonumber(split("/", var.vpc_cidr)[1]) <= 24 &&
      cidrsubnet(var.vpc_cidr, 4, 10) != "",
      false
    )
    error_message = "vpc_cidr must be a valid IPv4 /16-/24 CIDR with room for derived subnets."
  }
}

variable "availability_zone_count" {
  description = "Number of zones selected when availability_zones is empty."
  type        = number
  default     = 2

  validation {
    condition     = var.availability_zone_count >= 2 && var.availability_zone_count <= 3
    error_message = "availability_zone_count must be 2 or 3."
  }
}

variable "availability_zones" {
  description = "Optional explicit zone list, such as ap-southeast-2a and 2b."
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.availability_zones) == 0 || (length(var.availability_zones) >= 2 && length(var.availability_zones) <= 3)
    error_message = "availability_zones must be empty or contain 2-3 zones."
  }

  validation {
    condition     = length(distinct(var.availability_zones)) == length(var.availability_zones)
    error_message = "availability_zones must not contain duplicates."
  }
}

variable "nat_gateway_mode" {
  description = "Development defaults to one shared NAT gateway to limit cost."
  type        = string
  default     = "single"

  validation {
    condition     = contains(["none", "single", "per_az"], var.nat_gateway_mode)
    error_message = "nat_gateway_mode must be none, single, or per_az."
  }
}

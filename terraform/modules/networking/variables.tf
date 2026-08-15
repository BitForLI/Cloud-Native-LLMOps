variable "name" {
  description = "Stable prefix used to name and tag networking resources."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$", var.name))
    error_message = "name must be 3-32 lowercase alphanumeric or hyphen characters."
  }
}

variable "vpc_cidr" {
  description = "IPv4 CIDR used to derive non-overlapping public and private subnets."
  type        = string

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
  description = "Number of available zones selected when availability_zones is empty."
  type        = number
  default     = 2

  validation {
    condition     = var.availability_zone_count >= 2 && var.availability_zone_count <= 3
    error_message = "availability_zone_count must be 2 or 3."
  }
}

variable "availability_zones" {
  description = "Optional explicit zone list for deterministic subnet placement."
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
  description = "NAT topology: none, one shared gateway, or one gateway per AZ."
  type        = string
  default     = "single"

  validation {
    condition     = contains(["none", "single", "per_az"], var.nat_gateway_mode)
    error_message = "nat_gateway_mode must be none, single, or per_az."
  }
}

variable "create_s3_gateway_endpoint" {
  description = "Create a no-hourly-cost S3 gateway endpoint for private routes."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Additional tags merged onto every resource."
  type        = map(string)
  default     = {}
}

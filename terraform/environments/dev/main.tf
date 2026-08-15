terraform {
  required_version = ">= 1.7.0"
  required_providers { aws = { source = "hashicorp/aws", version = "~> 5.0" } }
}

provider "aws" { region = var.aws_region }

variable "aws_region" { type = string, default = "ap-southeast-2" }

module "networking" {
  source     = "../../modules/networking"
  name       = "llmops-dev"
  cidr_block = "10.20.0.0/16"
}

module "ecr" {
  source = "../../modules/ecr"
  name   = "llmops-api-dev"
}


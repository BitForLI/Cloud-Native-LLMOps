mock_provider "aws" {}

run "single_nat_development_topology" {
  command = plan

  variables {
    availability_zones = ["ap-southeast-2a", "ap-southeast-2b"]
    nat_gateway_mode   = "single"
  }

  assert {
    condition     = length(output.public_subnet_ids) == 2
    error_message = "Development must create one public subnet per configured AZ."
  }

  assert {
    condition     = length(output.private_subnet_ids) == 2
    error_message = "Development must create one private subnet per configured AZ."
  }

  assert {
    condition     = length(output.nat_gateway_ids) == 1
    error_message = "single mode must create exactly one NAT gateway."
  }
}

run "per_az_nat_topology" {
  command = plan

  variables {
    availability_zones = ["ap-southeast-2a", "ap-southeast-2b"]
    nat_gateway_mode   = "per_az"
  }

  assert {
    condition     = length(output.nat_gateway_ids) == 2
    error_message = "per_az mode must create one NAT gateway per configured AZ."
  }
}

run "isolated_topology_without_nat" {
  command = plan

  variables {
    availability_zones = ["ap-southeast-2a", "ap-southeast-2b"]
    nat_gateway_mode   = "none"
  }

  assert {
    condition     = length(output.nat_gateway_ids) == 0
    error_message = "none mode must not create NAT gateways."
  }
}

run "rejects_invalid_nat_mode" {
  command = plan

  variables {
    availability_zones = ["ap-southeast-2a", "ap-southeast-2b"]
    nat_gateway_mode   = "invalid"
  }

  expect_failures = [var.nat_gateway_mode]
}

run "rejects_ipv6_vpc_cidr" {
  command = plan

  variables {
    availability_zones = ["ap-southeast-2a", "ap-southeast-2b"]
    vpc_cidr           = "2001:db8::/56"
  }

  expect_failures = [var.vpc_cidr]
}

run "rejects_vpc_too_small_for_subnet_plan" {
  command = plan

  variables {
    availability_zones = ["ap-southeast-2a", "ap-southeast-2b"]
    vpc_cidr           = "10.20.0.0/28"
  }

  expect_failures = [var.vpc_cidr]
}

run "rejects_duplicate_availability_zones" {
  command = plan

  variables {
    availability_zones = ["ap-southeast-2a", "ap-southeast-2a"]
  }

  expect_failures = [var.availability_zones]
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_region" "current" {}

locals {
  availability_zones = length(var.availability_zones) > 0 ? var.availability_zones : slice(
    data.aws_availability_zones.available.names,
    0,
    var.availability_zone_count
  )
  common_tags = merge(var.tags, { Project = var.name })
  nat_gateway_zones = toset(
    var.nat_gateway_mode == "none" ? [] : (
      var.nat_gateway_mode == "single" ? [local.availability_zones[0]] : local.availability_zones
    )
  )
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(local.common_tags, { Name = "${var.name}-vpc" })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.common_tags, { Name = "${var.name}-igw" })
}

resource "aws_subnet" "public" {
  for_each = toset(local.availability_zones)

  vpc_id                  = aws_vpc.this.id
  availability_zone       = each.key
  cidr_block              = cidrsubnet(var.vpc_cidr, 4, index(local.availability_zones, each.key))
  map_public_ip_on_launch = false

  tags = merge(local.common_tags, {
    Name = "${var.name}-public-${each.key}"
    Tier = "public"
  })
}

resource "aws_subnet" "private" {
  for_each = toset(local.availability_zones)

  vpc_id            = aws_vpc.this.id
  availability_zone = each.key
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, 8 + index(local.availability_zones, each.key))

  tags = merge(local.common_tags, {
    Name = "${var.name}-private-${each.key}"
    Tier = "private"
  })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.common_tags, { Name = "${var.name}-public-rt" })
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_eip" "nat" {
  for_each = local.nat_gateway_zones

  domain = "vpc"

  tags       = merge(local.common_tags, { Name = "${var.name}-nat-eip-${each.key}" })
  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  for_each = local.nat_gateway_zones

  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = aws_subnet.public[each.key].id

  tags       = merge(local.common_tags, { Name = "${var.name}-nat-${each.key}" })
  depends_on = [aws_internet_gateway.this]
}

resource "aws_route_table" "private" {
  for_each = aws_subnet.private

  vpc_id = aws_vpc.this.id

  tags = merge(local.common_tags, { Name = "${var.name}-private-rt-${each.key}" })
}

resource "aws_route" "private_nat" {
  for_each = var.nat_gateway_mode == "none" ? {} : aws_route_table.private

  route_table_id         = each.value.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id = aws_nat_gateway.this[
    var.nat_gateway_mode == "single" ? local.availability_zones[0] : each.key
  ].id
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[each.key].id
}

resource "aws_vpc_endpoint" "s3" {
  count = var.create_s3_gateway_endpoint ? 1 : 0

  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [for route_table in aws_route_table.private : route_table.id]

  tags = merge(local.common_tags, { Name = "${var.name}-s3-endpoint" })
}

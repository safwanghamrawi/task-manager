################################################################################
# VPC: public subnets for the load balancer, private subnets for everything
# that matters.
#
# This is the same two-tier split the compose stack made with its `edge` and
# `internal` Docker networks, enforced by routing tables instead of by Docker:
# the tasks and the database have no route from the internet at all, and the
# database has no route TO the internet either.
################################################################################

resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr

  # Required for RDS and for the interface endpoints below to resolve.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = local.name }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = { Name = local.name }
}

# --- Subnets ----------------------------------------------------------------
# /20 each out of the /16: 4091 usable addresses per subnet. Fargate consumes
# one ENI (and therefore one address) per task, so the private subnets need
# real room — this is the constraint people hit first when they copy a /24.

resource "aws_subnet" "public" {
  for_each = { for index, az in local.azs : az => index }

  vpc_id                  = aws_vpc.main.id
  availability_zone       = each.key
  cidr_block              = cidrsubnet(var.vpc_cidr, 4, each.value)
  map_public_ip_on_launch = false

  tags = {
    Name = "${local.name}-public-${each.key}"
    Tier = "public"
  }
}

resource "aws_subnet" "private" {
  for_each = { for index, az in local.azs : az => index }

  vpc_id            = aws_vpc.main.id
  availability_zone = each.key
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, each.value + 8)

  tags = {
    Name = "${local.name}-private-${each.key}"
    Tier = "private"
  }
}

# --- NAT --------------------------------------------------------------------
# Private tasks need outbound access to pull from ECR, write to CloudWatch and
# read from Secrets Manager. Nothing needs to reach them.

locals {
  nat_azs = var.single_nat_gateway ? [local.azs[0]] : local.azs
}

resource "aws_eip" "nat" {
  for_each = toset(local.nat_azs)

  domain = "vpc"

  tags = { Name = "${local.name}-nat-${each.key}" }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_nat_gateway" "main" {
  for_each = toset(local.nat_azs)

  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = aws_subnet.public[each.key].id

  tags = { Name = "${local.name}-${each.key}" }

  depends_on = [aws_internet_gateway.main]
}

# --- Routing ----------------------------------------------------------------

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${local.name}-public" }
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  for_each = aws_subnet.private

  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    # With single_nat_gateway both AZs route through the first AZ's gateway.
    nat_gateway_id = aws_nat_gateway.main[var.single_nat_gateway ? local.azs[0] : each.key].id
  }

  tags = { Name = "${local.name}-private-${each.key}" }
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[each.key].id
}

# --- VPC endpoints ----------------------------------------------------------
# The S3 gateway endpoint is free and carries every ECR layer download, which
# is the overwhelming majority of a task's outbound bytes. Without it those
# bytes are billed twice: once by the NAT gateway, once as data transfer.

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${local.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [for rt in aws_route_table.private : rt.id]

  tags = { Name = "${local.name}-s3" }
}

# --- Flow logs --------------------------------------------------------------
# The only record of a connection that was refused. Rejected traffic only, so
# the volume stays proportional to attack traffic rather than to real traffic.

resource "aws_flow_log" "rejects" {
  vpc_id                   = aws_vpc.main.id
  traffic_type             = "REJECT"
  log_destination_type     = "cloud-watch-logs"
  log_destination          = aws_cloudwatch_log_group.flow_logs.arn
  iam_role_arn             = aws_iam_role.flow_logs.arn
  max_aggregation_interval = 600

  tags = { Name = "${local.name}-rejects" }
}

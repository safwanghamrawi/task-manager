################################################################################
# Security groups. Every rule between tiers references the peer group rather
# than a CIDR, so the policy stays correct when subnets are resized and cannot
# accidentally admit a neighbour that happens to share the range.
#
# The chain is strictly one-directional:
#   internet -> alb -> frontend
#                   -> backend -> rds
################################################################################

resource "aws_security_group" "alb" {
  name        = "${local.name}-alb"
  description = "Public entry point. The only group reachable from the internet."
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name}-alb" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from anywhere (redirected to HTTPS when a certificate is configured)"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  count = local.tls_enabled ? 1 : 0

  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from anywhere"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_frontend" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Forward to frontend tasks"
  referenced_security_group_id = aws_security_group.frontend.id
  from_port                    = 3000
  to_port                      = 3000
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_backend" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Forward to backend tasks"
  referenced_security_group_id = aws_security_group.backend.id
  from_port                    = 8000
  to_port                      = 8000
  ip_protocol                  = "tcp"
}

# --- Application tasks ------------------------------------------------------

resource "aws_security_group" "backend" {
  name        = "${local.name}-backend"
  description = "Backend Fargate tasks. Reachable only from the load balancer."
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name}-backend" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "backend_from_alb" {
  security_group_id            = aws_security_group.backend.id
  description                  = "uvicorn, from the load balancer only"
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 8000
  to_port                      = 8000
  ip_protocol                  = "tcp"
}

# Outbound is unrestricted because a task legitimately needs ECR, CloudWatch,
# Secrets Manager, SSM (for ECS Exec) and the database — nearly all of them on
# 443 to a prefix list that changes without notice. Restricting this to
# specific egress destinations is worth doing with VPC endpoints, not with a
# hand-maintained list of AWS IP ranges.
resource "aws_vpc_security_group_egress_rule" "backend_all" {
  security_group_id = aws_security_group.backend.id
  description       = "ECR, CloudWatch, Secrets Manager, SSM and PostgreSQL"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_security_group" "frontend" {
  name        = "${local.name}-frontend"
  description = "Frontend Fargate tasks. Reachable only from the load balancer."
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name}-frontend" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "frontend_from_alb" {
  security_group_id            = aws_security_group.frontend.id
  description                  = "Next.js standalone server, from the load balancer only"
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 3000
  to_port                      = 3000
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "frontend_all" {
  security_group_id = aws_security_group.frontend.id
  description       = "ECR, CloudWatch and SSM"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# --- Database ---------------------------------------------------------------
# No egress rule at all: the database has nothing to say to anyone. It answers
# the backend and that is the entirety of its network life.

resource "aws_security_group" "rds" {
  name        = "${local.name}-rds"
  description = "PostgreSQL. Reachable only from the backend tasks."
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name}-rds" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_backend" {
  security_group_id            = aws_security_group.rds.id
  description                  = "PostgreSQL from the backend tasks only"
  referenced_security_group_id = aws_security_group.backend.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

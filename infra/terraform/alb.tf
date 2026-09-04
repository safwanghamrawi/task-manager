################################################################################
# Application Load Balancer — the replacement for Traefik.
#
# Traefik discovered its routes from Docker labels on a single host. An ALB
# cannot do that, so the routing table that lived in docker-compose.yml labels
# is expressed here as listener rules. The mapping is one-for-one:
#
#   Traefik router (priority)              ->  ALB listener rule (priority)
#   backend-admin, IP allowlist (200)      ->  10..N (allow, one per CIDR)
#                                              100   (403 for everyone else)
#   backend, PathPrefix(/api) (100)        ->  200
#   frontend, PathPrefix(/) (1)            ->  default action
#
# Note that ALB priorities run the other way to Traefik's: lowest number wins.
#
# What an ALB does that Traefik-on-one-host could not: it lives in two AZs, it
# is not a container that can crash, and it is not sharing a CPU with the
# application it fronts.
################################################################################

resource "aws_lb" "main" {
  name               = local.name
  load_balancer_type = "application"
  internal           = false

  subnets         = [for subnet in aws_subnet.public : subnet.id]
  security_groups = [aws_security_group.alb.id]

  enable_deletion_protection = var.enable_deletion_protection
  # Longer than the frontend's slowest first paint, shorter than the 350s
  # default that keeps dead connections around after a deployment.
  idle_timeout = 60

  # Reject rather than forward ambiguous requests. Request smuggling starts
  # with a header the proxy and the origin parse differently.
  desync_mitigation_mode           = "strictest"
  drop_invalid_header_fields       = true
  enable_cross_zone_load_balancing = true
  # The X-Forwarded-For the backend's middleware reads for client_ip.
  xff_header_processing_mode = "append"

  tags = { Name = local.name }
}

# --- Target groups ----------------------------------------------------------
# `target_type = ip` is mandatory for Fargate: a task has its own ENI and its
# own address, and there is no instance to register.

resource "aws_lb_target_group" "backend" {
  name        = "${local.tg_prefix}-backend"
  port        = 8000
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.main.id

  # Long enough for uvicorn's 20s graceful shutdown to finish draining. Too
  # short and a rolling deployment kills requests that were mid-flight; this
  # is the setting that makes the deploy actually zero-downtime.
  deregistration_delay = 30

  health_check {
    enabled  = true
    path     = "/health/ready"
    protocol = "HTTP"
    matcher  = "200"
    # Readiness, not liveness: a task whose database round-trip fails answers
    # 503 here and the ALB stops sending it traffic. ECS does not kill it —
    # see docs/DECISIONS.md on why restarting fixes nothing during a failover.
    interval            = 10
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  # The API is stateless, so there is nothing to pin a client to.
  stickiness {
    type    = "lb_cookie"
    enabled = false
  }

  tags = { Name = "${local.name}-backend" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_target_group" "frontend" {
  name        = "${local.tg_prefix}-frontend"
  port        = 3000
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.main.id

  deregistration_delay = 20

  health_check {
    enabled = true
    # Deliberately does not depend on the backend: see
    # frontend/src/app/healthz/route.ts.
    path                = "/healthz"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 10
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  stickiness {
    type    = "lb_cookie"
    enabled = false
  }

  tags = { Name = "${local.name}-frontend" }

  lifecycle {
    create_before_destroy = true
  }
}

# --- Listeners --------------------------------------------------------------

locals {
  tls_enabled = var.acm_certificate_arn != ""

  # Rules attach to whichever listener actually serves the application.
  app_listener_arn = local.tls_enabled ? aws_lb_listener.https[0].arn : aws_lb_listener.http.arn

  # ALB caps a rule at five "condition values", counted across every condition
  # in the rule, not per condition. Seven exact patterns exceeded it outright;
  # four wildcards plus one source-IP CIDR is exactly five, which is why the
  # allow rules below are generated one per CIDR rather than one rule holding
  # all of them.
  #
  # The trade-off of the wildcard form: "/docs*" also matches "/documentation".
  # That is acceptable here because the frontend serves only "/" and
  # "/healthz" — but it is a real over-match, and a future frontend route
  # beginning with one of these prefixes would be answered by the backend (on
  # an allow rule) or a 403 (on the deny rule) instead of by the UI.
  admin_path_patterns = [
    "/docs*", # /docs and /docs/oauth2-redirect
    "/redoc*",
    "/openapi.json",
    "/metrics*",
  ]
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  # With a certificate, port 80 exists only to send people to port 443.
  dynamic "default_action" {
    for_each = local.tls_enabled ? [1] : []
    content {
      type = "redirect"
      redirect {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
  }

  dynamic "default_action" {
    for_each = local.tls_enabled ? [] : [1]
    content {
      type             = "forward"
      target_group_arn = aws_lb_target_group.frontend.arn
    }
  }
}

resource "aws_lb_listener" "https" {
  count = local.tls_enabled ? 1 : 0

  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  certificate_arn   = var.acm_certificate_arn
  # TLS 1.2 floor, matching the Traefik tls options this replaces.
  ssl_policy = "ELBSecurityPolicy-TLS13-1-2-2021-06"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.frontend.arn
  }
}

# --- Rules ------------------------------------------------------------------
# Rule 10 and rule 20 together are the `admin-allowlist` middleware: an ALB
# rule can only allow, so "deny everyone else" is a second, lower-priority
# rule that matches the same paths and answers 403 itself. The request never
# reaches a task either way.
#
# The source_ip condition matches the address in X-Forwarded-For when the ALB
# is fronted by CloudFront, and the TCP peer otherwise — which is what makes
# this correct on a bare ALB and something to re-check the day a CDN is added.

# One rule per allowed CIDR. Putting every CIDR in a single rule would be
# tidier, but four path values plus N CIDRs breaks the five-value cap as soon
# as N > 1 — and it would break at apply time, on a stranger's change to a
# variable, rather than here. Splitting keeps each rule at exactly five values
# regardless of how many CIDRs are configured.
resource "aws_lb_listener_rule" "admin_allowed" {
  for_each = { for index, cidr in var.admin_allowed_cidrs : cidr => index }

  listener_arn = local.app_listener_arn
  # 10, 11, 12 ... always below the deny rule at 100.
  priority = 10 + each.value

  condition {
    path_pattern {
      values = local.admin_path_patterns
    }
  }

  condition {
    source_ip {
      values = [each.key]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.backend.arn
  }

  tags = { Name = "${local.name}-admin-allowed-${each.value}" }
}

resource "aws_lb_listener_rule" "admin_denied" {
  listener_arn = local.app_listener_arn
  # 100, not 20: the allow rules above start at 10 and grow with the number of
  # configured CIDRs. This must stay below every allow rule and above nothing.
  priority = 100

  condition {
    path_pattern {
      values = local.admin_path_patterns
    }
  }

  action {
    type = "fixed-response"

    fixed_response {
      content_type = "application/json"
      # Same error shape the API itself returns, so a client parsing errors
      # does not need a special case for the ones the edge generates.
      message_body = jsonencode({
        error = {
          code    = "forbidden"
          message = "This endpoint is restricted to an allowlisted network."
        }
      })
      status_code = "403"
    }
  }

  tags = { Name = "${local.name}-admin-denied" }
}

resource "aws_lb_listener_rule" "api" {
  listener_arn = local.app_listener_arn
  priority     = 200

  condition {
    path_pattern {
      # The backend mounts its router at /api itself — nothing is stripped,
      # exactly as with the Traefik rule this replaces.
      values = ["/api", "/api/*"]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.backend.arn
  }

  tags = { Name = "${local.name}-api" }
}

# Everything else falls through to the listener's default action, which is the
# frontend. That is the `PathPrefix(/)` catch-all at priority 1.

################################################################################
# WAF — the replacement for Traefik's per-client rate limit.
#
# An ALB listener rule can match a request but cannot count one, so the rate
# limit could not simply move into alb.tf. A WAFv2 rate-based rule is the
# equivalent primitive, with one behavioural difference worth knowing: Traefik
# measured a per-second average with a burst allowance, WAF counts requests
# per source IP over a trailing five-minute window. `waf_rate_limit` is
# therefore a five-minute figure, not a per-second one.
#
# Scoped to /api. The frontend serves static assets and would trip a limit
# sized for API calls on a single page load.
################################################################################

resource "aws_wafv2_web_acl" "main" {
  count = var.enable_waf ? 1 : 0

  name        = local.name
  description = "Rate limiting for ${local.name}"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  rule {
    name     = "api-rate-limit"
    priority = 10

    action {
      block {
        custom_response {
          response_code = 429

          response_header {
            name  = "retry-after"
            value = "60"
          }
        }
      }
    }

    statement {
      rate_based_statement {
        limit              = var.waf_rate_limit
        aggregate_key_type = "IP"

        scope_down_statement {
          byte_match_statement {
            positional_constraint = "STARTS_WITH"
            search_string         = "/api"

            field_to_match {
              uri_path {}
            }

            text_transformation {
              priority = 0
              type     = "NONE"
            }
          }
        }
      }
    }

    visibility_config {
      sampled_requests_enabled   = true
      cloudwatch_metrics_enabled = true
      metric_name                = "${replace(local.name, "-", "")}ApiRateLimit"
    }
  }

  visibility_config {
    sampled_requests_enabled   = true
    cloudwatch_metrics_enabled = true
    metric_name                = replace(local.name, "-", "")
  }

  tags = { Name = local.name }
}

resource "aws_wafv2_web_acl_association" "main" {
  count = var.enable_waf ? 1 : 0

  resource_arn = aws_lb.main.arn
  web_acl_arn  = aws_wafv2_web_acl.main[0].arn
}

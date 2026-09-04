################################################################################
# TLS certificate.
#
# Two ways to get one, in order of precedence:
#
#   1. var.acm_certificate_arn — bring your own, issued elsewhere. Nothing here
#      is created.
#   2. var.domain_name — Terraform requests one and validates it by DNS.
#
# Whether Terraform can also *place* the validation record depends on where the
# zone lives:
#
#   * var.route53_zone_id set — the record is created here and validation
#     completes inside a single apply.
#   * zone hosted elsewhere — Terraform cannot write the record. It is exposed
#     as the `acm_validation_record` output; add it at your provider, then
#     apply again. See the two-phase note in README.md.
################################################################################

locals {
  # Terraform manages the certificate only when a domain is given and no
  # existing ARN was supplied.
  create_certificate = var.domain_name != "" && var.acm_certificate_arn == "" ? 1 : 0

  # Route 53 validation is a further opt-in: without a zone id the record has
  # to be placed by hand, and a validation resource would block on it.
  manage_validation = local.create_certificate == 1 && var.route53_zone_id != "" ? 1 : 0
}

resource "aws_acm_certificate" "main" {
  count = local.create_certificate

  domain_name       = var.domain_name
  validation_method = "DNS"

  # An in-place certificate swap would briefly leave the listener without one.
  # Create the replacement first, move the listener, then destroy the old.
  lifecycle {
    create_before_destroy = true
  }

  tags = { Name = "${local.name}-${var.domain_name}" }
}

# --- Route 53 validation, when the zone is ours -----------------------------

resource "aws_route53_record" "cert_validation" {
  for_each = local.manage_validation == 1 ? {
    for dvo in flatten(aws_acm_certificate.main[*].domain_validation_options) :
    dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  } : {}

  zone_id = var.route53_zone_id
  name    = each.value.name
  type    = each.value.type
  records = [each.value.record]
  ttl     = 60

  # ACM re-reads this record to renew. `allow_overwrite` keeps a re-apply from
  # failing on a record it created itself.
  allow_overwrite = true
}

# Blocks until ACM reports ISSUED, so the listener below can never be handed a
# PENDING_VALIDATION certificate — which an ALB refuses.
#
# Only created when Route 53 places the record. With an external zone this
# would poll for the full timeout while waiting for a human, so validation is
# confirmed by the second apply instead.
resource "aws_acm_certificate_validation" "main" {
  count = local.manage_validation

  certificate_arn         = aws_acm_certificate.main[0].arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]

  timeouts {
    create = "10m"
  }
}

################################################################################
# Copy to terraform.tfvars and edit. The result is gitignored.
#
#   cp terraform.tfvars.example terraform.tfvars
#
# Every value here has a working default in variables.tf; this file exists to
# show the ones you are most likely to want to change, and why.
################################################################################

# --- Identity ---------------------------------------------------------------
project     = "task-manager"
environment = "production"
aws_region  = "eu-west-1"

availability_zones = ["eu-west-1a", "eu-west-1b"]

# --- CI ---------------------------------------------------------------------
# Set this to wire up keyless deployments. Terraform creates a role that only
# this repository can assume, and `terraform output github_deploy_role_arn`
# gives you the value for the AWS_DEPLOY_ROLE_ARN repository variable.
github_repository = "safwanghamrawi/task-manager"

# Numeric IDs from the immutable OIDC subject claim GitHub now issues, read
# from the CloudTrail record of a failed assume-role:
#   repo:safwanghamrawi@3163835/task-manager@1353555273:ref:refs/heads/main
# Pinning them is stricter than matching on the owner/repo names alone.
github_owner_id      = "3163835"
github_repository_id = "1353555273"

# If another stack in this account already created GitHub's OIDC provider,
# pass its ARN — an account can only hold one.
# github_oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"

# --- Cost / availability trade-offs -----------------------------------------
# The three settings below are the ones that actually move the bill. Defaults
# are the cheap side of each; the comments say what you give up.

# One NAT gateway instead of two (~$32/mo saved). Costs you: outbound traffic
# from both AZs depends on one AZ. Tasks in the surviving AZ keep serving but
# cannot pull an image until it returns.
single_nat_gateway = true

# A synchronous standby in the second AZ. This is the single biggest
# availability improvement available and roughly doubles the database cost.
# Leave false for a demo; turn it on for anything with an SLA.
db_multi_az = false

# db.t4g.micro is burstable. Sustained load exhausts CPU credits and the
# instance is throttled hard — watch the task-manager-production-db-cpu alarm
# before deciding this is enough.
db_instance_class = "db.t4g.micro"

# --- Sizing -----------------------------------------------------------------
# Fargate only accepts certain cpu/memory pairings: 512 CPU allows 1024-4096
# MiB, 256 allows 512-2048.
backend_cpu          = 512
backend_memory       = 1024
backend_min_capacity = 2
backend_max_capacity = 8

frontend_cpu          = 256
frontend_memory       = 512
frontend_min_capacity = 2
frontend_max_capacity = 4

# --- Edge -------------------------------------------------------------------
# Ranges allowed to reach /docs, /redoc, /openapi.json and /metrics. The
# default is private space only, which nothing on the internet matches — add
# your office or VPN range to browse the OpenAPI docs.
# admin_allowed_cidrs = ["203.0.113.0/24"]

# Without a certificate the stack is plain HTTP on port 80. With one, port 80
# redirects to 443 and nothing else. The certificate must be in aws_region.
# acm_certificate_arn = "arn:aws:acm:eu-west-1:123456789012:certificate/..."

# Requests per source IP per five minutes before WAF blocks /api. Raise this
# before running loadtest/k6-load-test.js, which deliberately sends far more
# than one client's fair share.
enable_waf     = true
waf_rate_limit = 12000

# --- Alerting ---------------------------------------------------------------
# Alarms evaluate either way; without a topic nothing is notified.
# alarm_topic_arn = "arn:aws:sns:eu-west-1:123456789012:ops-alerts"

# --- Safety -----------------------------------------------------------------
# Both default to the safe setting. Turn them off only to tear down a
# throwaway environment, and remember that db_deletion_protection = false plus
# `terraform destroy` is exactly as final as it sounds.
db_deletion_protection     = true
enable_deletion_protection = false

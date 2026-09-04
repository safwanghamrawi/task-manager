################################################################################
# Every knob the stack exposes. Defaults are sized for a small production
# deployment; infra/terraform/README.md lists what each tier actually costs.
################################################################################

# --- Identity ---------------------------------------------------------------

variable "project" {
  description = "Name prefix for every resource. Keep it short: some AWS names are length-capped."
  type        = string
  default     = "task-manager"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,20}$", var.project))
    error_message = "project must be lowercase alphanumeric with hyphens, 2-21 characters."
  }
}

variable "environment" {
  description = "Deployment environment. Part of every resource name."
  type        = string
  default     = "production"

  validation {
    condition     = contains(["development", "staging", "production"], var.environment)
    error_message = "environment must be development, staging or production."
  }
}

variable "cluster_name" {
  description = <<-DESC
    Override just the ECS cluster's name. Empty means "<project>-<environment>",
    like every other resource.

    An ECS cluster name cannot be changed in place — AWS has no rename API — so
    setting this destroys the cluster and recreates it, taking both services
    with it. Everything else (load balancer, database, registries, IAM) is
    untouched, which is what makes this cheaper than renaming the whole stack
    by changing `project`. Expect downtime while the services are recreated.
  DESC
  type        = string
  default     = ""
}

variable "aws_region" {
  description = "Region to deploy into."
  type        = string
  default     = "eu-west-1"
}

variable "availability_zones" {
  description = "AZs to spread subnets across. The first two are used."
  type        = list(string)
  default     = ["eu-west-1a", "eu-west-1b"]

  validation {
    condition     = length(var.availability_zones) >= 2
    error_message = "At least two availability zones are required: an ALB will not start in one."
  }
}

# --- Network ----------------------------------------------------------------

variable "vpc_cidr" {
  description = "CIDR for the VPC. A /16 leaves room for the /20 subnets carved out of it."
  type        = string
  default     = "10.20.0.0/16"
}

variable "single_nat_gateway" {
  description = <<-DESC
    Run one NAT gateway for both private subnets instead of one per AZ.
    True halves the standing cost (~$32/mo each) at the price of a single-AZ
    dependency for outbound traffic: if that AZ fails, tasks in the other AZ
    keep serving requests but cannot pull a new image until it returns. Set to
    false for a real production SLA.
  DESC
  type        = bool
  default     = true
}

# --- Application ------------------------------------------------------------

variable "image_tag" {
  description = <<-DESC
    Tag the task definitions are created with. CI overrides this per
    deployment by registering a new revision, so this value only matters for
    the first apply and for an apply that recreates a task definition.
  DESC
  type        = string
  default     = "latest"
}

variable "backend_cpu" {
  description = "Fargate CPU units for one backend task (1024 = 1 vCPU)."
  type        = number
  default     = 512
}

variable "backend_memory" {
  description = "Fargate memory (MiB) for one backend task. Must be a valid pairing with backend_cpu."
  type        = number
  default     = 1024
}

variable "backend_desired_count" {
  description = "Backend tasks to run at rest. Autoscaling moves this between min and max."
  type        = number
  default     = 2
}

variable "backend_min_capacity" {
  description = "Floor for backend autoscaling. Two keeps a rolling deploy from ever dropping to a single replica."
  type        = number
  default     = 2
}

variable "backend_max_capacity" {
  description = <<-DESC
    Ceiling for backend autoscaling. Bounded by the database, not by Fargate:
    each task holds db_pool_size + db_max_overflow connections, and the product
    has to fit inside db_max_connections with room for psql, Performance
    Insights and a rolling deployment's extra tasks.
  DESC
  type        = number
  default     = 8

  validation {
    # 80% leaves headroom for the superuser reservation and monitoring.
    #
    # It does NOT cover a deployment running at the autoscaling ceiling:
    # deployment_maximum_percent is 200, so 8 tasks briefly become 16, and
    # 16 x 10 = 160 is over the 112 limit. That window is not defended here
    # on purpose — reaching 8 tasks of sustained load on a burstable
    # db.t4g.micro means the instance class is already wrong, and the fix is
    # a bigger database rather than a smaller pool. The db-connections alarm
    # fires at 80% to make that visible well before it matters.
    condition = (
      var.backend_max_capacity * (var.db_pool_size + var.db_max_overflow)
      <= var.db_max_connections * 0.8
    )
    error_message = <<-ERR
      Connection ceiling exceeded. backend_max_capacity x (db_pool_size +
      db_max_overflow) must stay at or under 80% of db_max_connections.
      Fix by lowering backend_max_capacity or the pool sizes, or by moving to a
      larger db_instance_class and raising db_max_connections to match.
    ERR
  }
}

variable "frontend_cpu" {
  description = "Fargate CPU units for one frontend task."
  type        = number
  default     = 256
}

variable "frontend_memory" {
  description = "Fargate memory (MiB) for one frontend task."
  type        = number
  default     = 512
}

variable "frontend_desired_count" {
  description = "Frontend tasks to run at rest."
  type        = number
  default     = 2
}

variable "frontend_min_capacity" {
  description = "Floor for frontend autoscaling."
  type        = number
  default     = 2
}

variable "frontend_max_capacity" {
  description = "Ceiling for frontend autoscaling."
  type        = number
  default     = 4
}

variable "log_level" {
  description = "Backend log level."
  type        = string
  default     = "INFO"
}

variable "db_auto_create_schema" {
  description = <<-DESC
    Let the backend create its tables on startup. Convenient, and safe while
    the schema is append-only, but every starting task runs it. Turn this off
    and run migrations as a one-off ECS task once Alembic is adopted — see
    docs/DECISIONS.md.
  DESC
  type        = bool
  default     = true
}

variable "max_tasks" {
  description = "Row cap the API enforces, as a crude runaway-growth guard."
  type        = number
  default     = 10000
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention. Logs are the only post-mortem evidence a stopped Fargate task leaves behind."
  type        = number
  default     = 30
}

# --- Database ---------------------------------------------------------------

variable "db_name" {
  description = "Initial database name."
  type        = string
  default     = "tasks"
}

variable "db_username" {
  description = "Master username. The password is generated into Secrets Manager and is never set here."
  type        = string
  default     = "taskmanager"
}

variable "db_pool_size" {
  description = "SQLAlchemy pool size per backend task. Every task holds its own pool."
  type        = number
  default     = 8
}

variable "db_max_overflow" {
  description = "Extra connections a task may open above db_pool_size under burst."
  type        = number
  default     = 2
}

variable "db_max_connections" {
  description = <<-DESC
    What PostgreSQL will actually accept, used to check the pool arithmetic
    below. RDS computes this from instance memory rather than exposing a flat
    number: LEAST({DBInstanceClassMemory/9531392}, 5000).

    db.t4g.micro has 1 GiB, which gives 112. Update this alongside
    db_instance_class — a bigger instance allows proportionally more.

    The demand side is backend_max_capacity x (db_pool_size + db_max_overflow),
    and it must stay comfortably under this. Exceeding it does not degrade
    gracefully: PostgreSQL refuses the connection and the request 503s.
  DESC
  type        = number
  default     = 112
}

variable "db_instance_class" {
  description = "RDS instance class. db.t4g.micro is Graviton and the cheapest class that is not burst-starved."
  type        = string
  default     = "db.t4g.micro"
}

variable "db_engine_version" {
  description = "PostgreSQL version. Tracks the postgres:17-alpine image used locally."
  type        = string
  default     = "17.5"
}

variable "db_allocated_storage" {
  description = "Initial storage (GiB). Storage autoscaling raises it up to db_max_allocated_storage."
  type        = number
  default     = 20
}

variable "db_max_allocated_storage" {
  description = "Ceiling for RDS storage autoscaling. A full volume takes the database read-only."
  type        = number
  default     = 100
}

variable "db_multi_az" {
  description = "Synchronous standby in the second AZ. Roughly doubles the database cost and is the single biggest availability win on offer."
  type        = bool
  default     = false
}

variable "db_backup_retention_days" {
  description = "Automated backup retention. Zero disables backups and point-in-time recovery — do not."
  type        = number
  default     = 7

  validation {
    condition     = var.db_backup_retention_days >= 1
    error_message = "Backups must be retained for at least one day."
  }
}

variable "db_deletion_protection" {
  description = "Refuse `terraform destroy` on the database. Leave true for anything holding real data."
  type        = bool
  default     = true
}

# --- Edge -------------------------------------------------------------------

variable "admin_allowed_cidrs" {
  description = <<-DESC
    Source ranges allowed to reach /docs, /redoc, /openapi.json and /metrics.
    Everything else gets a 403 from the load balancer, so the request never
    reaches a task. The default is private space only: nothing on the public
    internet matches it. Add your office or VPN range to browse the API docs.
  DESC
  type        = list(string)
  default     = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
}

variable "domain_name" {
  description = <<-DESC
    Hostname the application is served on, e.g. "task-manager.example.com".
    Setting it makes Terraform request an ACM certificate and enables the HTTPS
    listener; port 80 becomes a 301 redirect.

    Leave empty for plain HTTP on the load balancer's own hostname — a
    certificate cannot be issued for *.elb.amazonaws.com, because that is
    Amazon's domain and cannot be validated.

    Ignored when acm_certificate_arn is set.
  DESC
  type        = string
  default     = ""
}

variable "route53_zone_id" {
  description = <<-DESC
    Hosted zone for domain_name, when the zone is in this account's Route 53.
    Set it and Terraform writes the DNS validation record itself, so the
    certificate is issued within a single apply.

    Leave empty when DNS is hosted elsewhere. Terraform still requests the
    certificate; the record to add is published as the `acm_validation_record`
    output, and a second apply picks up the issued certificate.
  DESC
  type        = string
  default     = ""
}

variable "acm_certificate_arn" {
  description = <<-DESC
    ACM certificate for HTTPS. When set, the ALB gets a 443 listener and port
    80 does nothing but redirect to it. When empty the stack is plain HTTP on
    port 80 — fine for a demo, not for anything else.
  DESC
  type        = string
  default     = ""
}

variable "enable_waf" {
  description = <<-DESC
    Attach a WAFv2 web ACL with a rate-based rule in front of /api. This is
    what replaces Traefik's per-client rate limit: an ALB listener rule can
    match a request but cannot count one.
  DESC
  type        = bool
  default     = true
}

variable "waf_rate_limit" {
  description = "Requests per 5-minute window, per source IP, before WAF starts blocking /api."
  type        = number
  default     = 12000
}

variable "enable_deletion_protection" {
  description = "Deletion protection on the load balancer."
  type        = bool
  default     = false
}

variable "enable_container_insights" {
  description = "Container Insights on the ECS cluster. This replaces the Prometheus container that ran on the single host."
  type        = bool
  default     = true
}

variable "enable_execute_command" {
  description = <<-DESC
    Allow `aws ecs execute-command` into a running task. This is the ECS
    replacement for SSH: no inbound port, no key to leak, every session
    authorised by IAM and logged to CloudWatch.
  DESC
  type        = bool
  default     = true
}

# --- Alerting ---------------------------------------------------------------

variable "alarm_topic_arn" {
  description = <<-DESC
    SNS topic to notify on alarm. Empty leaves the alarms evaluating and
    visible in the console but notifying nobody — where an alert should go is
    an organisational decision, not a repository one.
  DESC
  type        = string
  default     = ""
}

# --- CI ---------------------------------------------------------------------

variable "github_repository" {
  description = <<-DESC
    owner/repo allowed to assume the deployment role through GitHub's OIDC
    provider. Empty skips creating the role — set it to wire up the keyless
    CI deployment.
  DESC
  type        = string
  default     = ""
}

variable "github_owner_id" {
  description = <<-DESC
    Numeric GitHub owner (user or org) ID, used in the immutable subject
    claim. Optional: leaving it empty falls back to a wildcard that still
    requires the exact owner *name*. Pin it to be strict about which account,
    not just which name.

    Find it after one failed run with:
      aws cloudtrail lookup-events \
        --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRoleWithWebIdentity \
        --max-results 1 --query 'Events[0].CloudTrailEvent' --output text | jq -r .userIdentity.userName
  DESC
  type        = string
  default     = ""

  validation {
    condition     = var.github_owner_id == "" || can(regex("^[0-9]+$", var.github_owner_id))
    error_message = "github_owner_id must be numeric, or empty."
  }
}

variable "github_repository_id" {
  description = "Numeric GitHub repository ID, used in the immutable subject claim. See github_owner_id."
  type        = string
  default     = ""

  validation {
    condition     = var.github_repository_id == "" || can(regex("^[0-9]+$", var.github_repository_id))
    error_message = "github_repository_id must be numeric, or empty."
  }
}

variable "github_trust_legacy_subject" {
  description = <<-DESC
    Also trust the old name-based subject claim,
    `repo:owner/name:ref:refs/heads/main`. Only needed for repositories
    created before 2026-07-15, which still issue it.

    Off by default because it is the shape GitHub moved away from: a name can
    be renamed, transferred and re-registered by someone else, and a policy
    trusting a name inherits that risk.
  DESC
  type        = bool
  default     = false
}

variable "github_oidc_provider_arn" {
  description = <<-DESC
    ARN of an existing GitHub OIDC provider in this account. Leave empty to
    have Terraform create one. An account can only hold one, so if another
    stack already created it, pass its ARN here.
  DESC
  type        = string
  default     = ""
}

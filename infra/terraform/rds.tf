################################################################################
# PostgreSQL on RDS.
#
# The `postgres:17-alpine` container in docker-compose.yml stays exactly where
# it is — for local development. It does not follow the application to
# Fargate: a task has no durable local disk, and putting the one stateful
# component of the system on an EFS volume shared by a scheduler that is free
# to kill and reschedule it is a worse database, not a cheaper one.
#
# What moves to AWS: backups, point-in-time recovery, minor-version patching,
# and an optional standby. What stays the same: the connection string shape,
# so the application code is unchanged.
################################################################################

resource "aws_db_subnet_group" "main" {
  name        = local.name
  description = "Private subnets only: the database has no route to the internet."
  subnet_ids  = [for subnet in aws_subnet.private : subnet.id]

  tags = { Name = local.name }
}

# Parameters that need a reboot to take effect are set here rather than by
# hand, so a replacement instance comes back configured the same way.
resource "aws_db_parameter_group" "main" {
  name_prefix = "${local.name}-"
  family      = "postgres${split(".", var.db_engine_version)[0]}"
  description = "${local.name} PostgreSQL parameters"

  parameter {
    # Refuse unencrypted connections. asyncpg negotiates TLS automatically, so
    # this costs the application nothing.
    name         = "rds.force_ssl"
    value        = "1"
    apply_method = "pending-reboot"
  }

  parameter {
    # Log any statement slower than a second. The API's queries are all
    # single-row or a bounded list; anything over 1s is a bug or a missing index.
    name  = "log_min_duration_statement"
    value = "1000"
  }

  parameter {
    name  = "log_connections"
    value = "1"
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = { Name = local.name }
}

# --- Credentials ------------------------------------------------------------
# Generated here and never seen by a human. The value reaches the container as
# a `secrets` entry in the task definition, which the ECS agent resolves at
# start-up — it is not an environment variable in the task definition JSON and
# does not appear in `describe-task-definition` output.

resource "random_password" "db" {
  length = 40
  # RDS rejects '/', '@', '"' and ' ' in a master password, and the value is
  # also interpolated into a URL below.
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_secretsmanager_secret" "db" {
  name_prefix = "${local.name}/database/"
  description = "PostgreSQL credentials and the async SQLAlchemy URL for ${local.name}"

  # Long enough to undo an accidental destroy, short enough that name_prefix
  # does not collide on the next apply.
  recovery_window_in_days = 7

  tags = { Name = "${local.name}-database" }
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id

  # Both shapes are stored: the URL is what the container consumes, the
  # individual fields are what an operator needs for `psql`.
  secret_string = jsonencode({
    username = var.db_username
    password = random_password.db.result
    host     = aws_db_instance.main.address
    port     = aws_db_instance.main.port
    dbname   = var.db_name
    url = format(
      "postgresql+asyncpg://%s:%s@%s:%d/%s",
      var.db_username,
      urlencode(random_password.db.result),
      aws_db_instance.main.address,
      aws_db_instance.main.port,
      var.db_name,
    )
  })
}

# --- Instance ---------------------------------------------------------------

resource "aws_db_instance" "main" {
  identifier = local.name

  engine         = "postgres"
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  db_name  = var.db_name
  username = var.db_username
  password = random_password.db.result
  port     = 5432

  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  parameter_group_name   = aws_db_parameter_group.main.name
  publicly_accessible    = false

  multi_az = var.db_multi_az

  backup_retention_period = var.db_backup_retention_days
  # Backup first, then patch, both outside the busiest hours. UTC.
  backup_window         = "02:00-03:00"
  maintenance_window    = "sun:03:30-sun:04:30"
  copy_tags_to_snapshot = true

  auto_minor_version_upgrade = true
  apply_immediately          = false

  performance_insights_enabled          = true
  performance_insights_retention_period = 7
  monitoring_interval                   = 60
  monitoring_role_arn                   = aws_iam_role.rds_monitoring.arn
  enabled_cloudwatch_logs_exports       = ["postgresql", "upgrade"]

  deletion_protection = var.db_deletion_protection
  # A final snapshot is the difference between a bad afternoon and a lost
  # database, and it costs nothing until it is needed.
  skip_final_snapshot       = false
  final_snapshot_identifier = "${local.name}-final-${formatdate("YYYYMMDDhhmmss", timestamp())}"

  lifecycle {
    ignore_changes = [
      # The timestamp above would otherwise re-plan on every single run.
      final_snapshot_identifier,
      # RDS applies minor versions during the maintenance window; Terraform
      # should not drag the instance back to the pinned version afterwards.
      engine_version,
    ]
  }

  tags = { Name = local.name }
}

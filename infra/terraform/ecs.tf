################################################################################
# ECS on Fargate.
#
# The unit of deployment is unchanged — the same two images, built by the same
# Dockerfiles, verified by the same test stage. What changes is who runs them:
# `docker compose up` on one box becomes a scheduler that places tasks across
# two AZs, replaces an unhealthy one without being asked, and rolls a new
# revision out behind the load balancer with the old one still serving.
#
# The container definitions below are the direct translation of the compose
# services. Where compose had `read_only`, `cap_drop`, `tmpfs` and
# `stop_grace_period`, Fargate has `readonlyRootFilesystem`, `linuxParameters`
# and `stopTimeout` — the hardening survives the move.
################################################################################

resource "aws_ecs_cluster" "main" {
  name = local.cluster_name

  setting {
    name  = "containerInsights"
    value = var.enable_container_insights ? "enabled" : "disabled"
  }

  dynamic "configuration" {
    for_each = var.enable_execute_command ? [1] : []
    content {
      execute_command_configuration {
        logging = "OVERRIDE"

        log_configuration {
          cloud_watch_log_group_name = aws_cloudwatch_log_group.exec.name
        }
      }
    }
  }

  tags = { Name = local.name }
}

# Fargate Spot is available but not used for the application: a Spot
# interruption gives two minutes' notice, which the API can absorb but which
# buys ~70% off a bill that is already small. Revisit if the fleet grows.
resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = ["FARGATE"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
    base              = 0
  }
}

locals {
  backend_image  = "${aws_ecr_repository.this["backend"].repository_url}:${var.image_tag}"
  frontend_image = "${aws_ecr_repository.this["frontend"].repository_url}:${var.image_tag}"

  private_subnet_ids = [for subnet in aws_subnet.private : subnet.id]
}

# --- Backend ----------------------------------------------------------------

resource "aws_ecs_task_definition" "backend" {
  family                   = "${local.name}-backend"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.backend_cpu
  memory                   = var.backend_memory

  execution_role_arn = aws_iam_role.execution.arn
  task_role_arn      = aws_iam_role.backend_task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    # The images are built for linux/amd64 in CI. Moving both to ARM64 is a
    # ~20% price cut and a one-line change in both places — not two.
    cpu_architecture = "X86_64"
  }

  container_definitions = jsonencode([{
    name      = "backend"
    image     = local.backend_image
    essential = true

    portMappings = [{
      name          = "http"
      containerPort = 8000
      # In awsvpc mode hostPort must equal containerPort, and ECS fills it in
      # regardless. Declaring it keeps `terraform plan` quiet — without it the
      # task definition is replaced on every single apply.
      hostPort = 8000
      protocol = "tcp"
    }]

    environment = [
      { name = "ENVIRONMENT", value = var.environment },
      { name = "LOG_LEVEL", value = var.log_level },
      { name = "DB_POOL_SIZE", value = tostring(var.db_pool_size) },
      { name = "DB_MAX_OVERFLOW", value = tostring(var.db_max_overflow) },
      { name = "DB_AUTO_CREATE_SCHEMA", value = tostring(var.db_auto_create_schema) },
      { name = "MAX_TASKS", value = tostring(var.max_tasks) },
      # Empty is correct: the browser calls /api on the origin it loaded the
      # page from, so there is no cross-origin request to permit.
      { name = "CORS_ORIGINS", value = "" },
    ]

    # Resolved by the ECS agent at start-up using the *execution* role. The
    # value is never in this JSON and never in describe-task-definition.
    secrets = [{
      name      = "DATABASE_URL"
      valueFrom = "${aws_secretsmanager_secret.db.arn}:url::"
    }]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.backend.name
        "awslogs-region"        = local.region
        "awslogs-stream-prefix" = "ecs"
        # The application already logs one JSON object per line; this tells
        # CloudWatch to keep them as such instead of splitting on newlines
        # inside a traceback.
        "mode"            = "non-blocking"
        "max-buffer-size" = "4m"
      }
    }

    # ECS's own check, in addition to the ALB's. Liveness only: if the
    # database is down, restarting the container fixes nothing and a
    # crash-loop makes recovery slower. Same reasoning as the Dockerfile's
    # HEALTHCHECK, which this overrides.
    healthCheck = {
      command     = ["CMD-SHELL", "curl --fail --silent http://127.0.0.1:8000/health/live || exit 1"]
      interval    = 15
      timeout     = 3
      retries     = 3
      startPeriod = 30
    }

    # Longer than uvicorn's 20s graceful shutdown, so draining wins the race
    # against SIGKILL. Matches stop_grace_period in docker-compose.yml.
    stopTimeout = 30

    readonlyRootFilesystem = true

    mountPoints = [{
      sourceVolume  = "tmp"
      containerPath = "/tmp"
      readOnly      = false
    }]

    linuxParameters = {
      # cap_drop: ALL. Fargate's platform already blocks most of what these
      # would grant, but the task definition is where an auditor looks.
      # `add = []` is echoed back by ECS, so it is declared for the same
      # reason as hostPort above.
      capabilities       = { add = [], drop = ["ALL"] }
      initProcessEnabled = var.enable_execute_command
    }

    ulimits = [{
      name      = "nofile"
      softLimit = 65536
      hardLimit = 65536
    }]
  }])

  # readonlyRootFilesystem leaves nowhere to write. The application only needs
  # /tmp, and it gets an ephemeral one.
  volume {
    name = "tmp"
  }

  lifecycle {
    precondition {
      condition = contains(
        lookup(local.fargate_memory_for_cpu, tostring(var.backend_cpu), []),
        var.backend_memory,
      )
      error_message = <<-ERR
        Invalid Fargate cpu/memory pairing: backend_cpu=${var.backend_cpu} with
        backend_memory=${var.backend_memory}. Fargate accepts only a fixed set, not a
        range. Valid memory for this cpu: ${join(", ", [
      for m in lookup(local.fargate_memory_for_cpu, tostring(var.backend_cpu), ["<unsupported cpu>"]) : tostring(m)
])}
      ERR
}
}

tags = { Name = "${local.name}-backend" }
}

resource "aws_ecs_service" "backend" {
  name            = "${local.name}-backend"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.backend.arn
  desired_count   = var.backend_desired_count
  launch_type     = "FARGATE"

  enable_execute_command = var.enable_execute_command
  propagate_tags         = "SERVICE"
  # Tasks are tagged with the service, which is what makes Container Insights
  # able to break metrics down per service.
  enable_ecs_managed_tags = true

  network_configuration {
    subnets          = local.private_subnet_ids
    security_groups  = [aws_security_group.backend.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.backend.arn
    container_name   = "backend"
    container_port   = 8000
  }

  # Rolling deployment with the old revision still serving: 200/100 means ECS
  # may run one extra task per replica while never dropping below the current
  # count. That is the zero-downtime property the EC2 deployment got from
  # `compose up -d` recreating containers one at a time — except here the load
  # balancer stops routing to the old task before it is stopped.
  deployment_maximum_percent         = 200
  deployment_minimum_healthy_percent = 100

  deployment_circuit_breaker {
    # A revision whose tasks will not stabilise is abandoned instead of
    # retried forever, and ECS puts the previous one back. This is the
    # automatic half of the rollback story; scripts/ecs-rollback.sh is the
    # half an operator drives.
    enable   = true
    rollback = true
  }

  # Do not start counting a task unhealthy while it is still booting.
  health_check_grace_period_seconds = 60

  # No placement strategy: Fargate rejects one, and the scheduler already
  # balances tasks across the AZs of the subnets above. Losing an AZ costs
  # half the capacity, never all of it.

  lifecycle {
    ignore_changes = [
      # CI registers a new revision per deployment and points the service at
      # it. Terraform owns the *shape* of the task definition, CI owns which
      # image tag is running — without this, the next `terraform apply` would
      # roll production back to whatever tag was last applied.
      task_definition,
      # Likewise for autoscaling, which owns desired_count at runtime.
      desired_count,
    ]
  }

  depends_on = [
    aws_lb_listener.http,
    aws_iam_role_policy.execution_secrets,
    # The task resolves DATABASE_URL from this version at start-up; without
    # the edge, the first tasks race the secret into existence and crash-loop.
    aws_secretsmanager_secret_version.db,
  ]

  tags = { Name = "${local.name}-backend" }
}

# --- Frontend ---------------------------------------------------------------

resource "aws_ecs_task_definition" "frontend" {
  family                   = "${local.name}-frontend"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.frontend_cpu
  memory                   = var.frontend_memory

  execution_role_arn = aws_iam_role.execution.arn
  task_role_arn      = aws_iam_role.frontend_task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([{
    name      = "frontend"
    image     = local.frontend_image
    essential = true

    portMappings = [{
      name          = "http"
      containerPort = 3000
      hostPort      = 3000
      protocol      = "tcp"
    }]

    environment = [
      { name = "NODE_ENV", value = "production" },
      { name = "PORT", value = "3000" },
      { name = "HOSTNAME", value = "0.0.0.0" },
      { name = "NEXT_TELEMETRY_DISABLED", value = "1" },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.frontend.name
        "awslogs-region"        = local.region
        "awslogs-stream-prefix" = "ecs"
        "mode"                  = "non-blocking"
        "max-buffer-size"       = "4m"
      }
    }

    healthCheck = {
      command     = ["CMD-SHELL", "wget --quiet --spider --tries=1 http://127.0.0.1:3000/healthz || exit 1"]
      interval    = 15
      timeout     = 3
      retries     = 3
      startPeriod = 20
    }

    stopTimeout = 20

    readonlyRootFilesystem = true

    mountPoints = [{
      sourceVolume  = "tmp"
      containerPath = "/tmp"
      readOnly      = false
    }]

    linuxParameters = {
      capabilities       = { add = [], drop = ["ALL"] }
      initProcessEnabled = var.enable_execute_command
    }
  }])

  volume {
    name = "tmp"
  }

  lifecycle {
    precondition {
      condition = contains(
        lookup(local.fargate_memory_for_cpu, tostring(var.frontend_cpu), []),
        var.frontend_memory,
      )
      error_message = <<-ERR
        Invalid Fargate cpu/memory pairing: frontend_cpu=${var.frontend_cpu} with
        frontend_memory=${var.frontend_memory}. Fargate accepts only a fixed set, not a
        range. Valid memory for this cpu: ${join(", ", [
      for m in lookup(local.fargate_memory_for_cpu, tostring(var.frontend_cpu), ["<unsupported cpu>"]) : tostring(m)
])}
      ERR
}
}

tags = { Name = "${local.name}-frontend" }
}

resource "aws_ecs_service" "frontend" {
  name            = "${local.name}-frontend"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.frontend.arn
  desired_count   = var.frontend_desired_count
  launch_type     = "FARGATE"

  enable_execute_command  = var.enable_execute_command
  propagate_tags          = "SERVICE"
  enable_ecs_managed_tags = true

  network_configuration {
    subnets          = local.private_subnet_ids
    security_groups  = [aws_security_group.frontend.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.frontend.arn
    container_name   = "frontend"
    container_port   = 3000
  }

  deployment_maximum_percent         = 200
  deployment_minimum_healthy_percent = 100

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  health_check_grace_period_seconds = 45

  lifecycle {
    ignore_changes = [task_definition, desired_count]
  }

  depends_on = [aws_lb_listener.http]

  tags = { Name = "${local.name}-frontend" }
}

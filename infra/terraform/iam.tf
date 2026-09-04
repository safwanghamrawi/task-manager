################################################################################
# IAM.
#
# The EC2 deployment's privilege story was "a deploy user in the docker group,
# with no sudo". On ECS the equivalent question is asked three times, and each
# answer is a separate role:
#
#   execution role - what the ECS *agent* may do to start the task
#                    (pull the image, fetch the secret, write logs)
#   task role      - what the *application* may do once running
#   CI role        - what GitHub Actions may do to deploy
#
# Splitting the first two matters: a compromised container inherits the task
# role, never the execution role, so it cannot read the database secret out of
# Secrets Manager even though the secret is injected into its own environment.
################################################################################

# --- Task execution role ----------------------------------------------------

data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }

    # Only this account's ECS may assume these roles — the confused-deputy
    # guard AWS documents for every service principal.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "${local.name}-execution"
  description        = "Used by the ECS agent to start a task: pull, decrypt, log."
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json

  tags = { Name = "${local.name}-execution" }
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# The managed policy above covers ECR and CloudWatch but not Secrets Manager,
# and it grants ecr:* on every repository. This narrows the secret read to the
# one secret this stack owns.
data "aws_iam_policy_document" "execution_secrets" {
  statement {
    sid       = "ReadDatabaseSecret"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.db.arn]
  }
}

resource "aws_iam_role_policy" "execution_secrets" {
  name   = "read-database-secret"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution_secrets.json
}

# --- Task roles -------------------------------------------------------------
# The application itself calls no AWS API. These roles exist so that ECS Exec
# has something to attach its SSM permissions to, and so that the day the
# application does need S3 or SQS, the grant lands in an obvious place instead
# of on the execution role.

data "aws_iam_policy_document" "exec_channel" {
  statement {
    sid = "EcsExecSsmChannel"
    actions = [
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
    ]
    resources = ["*"] # These actions do not support resource-level permissions.
  }

  statement {
    sid = "EcsExecSessionLogging"
    actions = [
      "logs:DescribeLogGroups",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [
      aws_cloudwatch_log_group.exec.arn,
      "${aws_cloudwatch_log_group.exec.arn}:*",
    ]
  }
}

resource "aws_iam_role" "backend_task" {
  name               = "${local.name}-backend-task"
  description        = "Assumed by the backend container itself."
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json

  tags = { Name = "${local.name}-backend-task" }
}

resource "aws_iam_role" "frontend_task" {
  name               = "${local.name}-frontend-task"
  description        = "Assumed by the frontend container itself."
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json

  tags = { Name = "${local.name}-frontend-task" }
}

resource "aws_iam_role_policy" "backend_exec" {
  count = var.enable_execute_command ? 1 : 0

  name   = "ecs-exec"
  role   = aws_iam_role.backend_task.id
  policy = data.aws_iam_policy_document.exec_channel.json
}

resource "aws_iam_role_policy" "frontend_exec" {
  count = var.enable_execute_command ? 1 : 0

  name   = "ecs-exec"
  role   = aws_iam_role.frontend_task.id
  policy = data.aws_iam_policy_document.exec_channel.json
}

# --- RDS enhanced monitoring ------------------------------------------------

data "aws_iam_policy_document" "rds_monitoring_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["monitoring.rds.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "rds_monitoring" {
  name               = "${local.name}-rds-monitoring"
  assume_role_policy = data.aws_iam_policy_document.rds_monitoring_assume.json

  tags = { Name = "${local.name}-rds-monitoring" }
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# --- VPC flow logs ----------------------------------------------------------

data "aws_iam_policy_document" "flow_logs_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "flow_logs" {
  name               = "${local.name}-flow-logs"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_assume.json

  tags = { Name = "${local.name}-flow-logs" }
}

resource "aws_iam_role_policy" "flow_logs" {
  name = "write-flow-logs"
  role = aws_iam_role.flow_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogStreams",
      ]
      Resource = "${aws_cloudwatch_log_group.flow_logs.arn}:*"
    }]
  })
}

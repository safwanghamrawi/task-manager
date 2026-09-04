################################################################################
# CloudWatch log groups.
#
# On the single host, `docker logs` was the record and json-file rotation kept
# it from filling the disk. A stopped Fargate task leaves nothing behind, so
# the log group IS the post-mortem: it is created here with an explicit
# retention rather than being auto-created by the agent with retention set to
# "forever".
################################################################################

resource "aws_cloudwatch_log_group" "backend" {
  name              = "/ecs/${local.name}/backend"
  retention_in_days = var.log_retention_days

  tags = { Name = "${local.name}-backend" }
}

resource "aws_cloudwatch_log_group" "frontend" {
  name              = "/ecs/${local.name}/frontend"
  retention_in_days = var.log_retention_days

  tags = { Name = "${local.name}-frontend" }
}

# ECS Exec sessions are recorded here: who ran what, inside which task.
resource "aws_cloudwatch_log_group" "exec" {
  name              = "/ecs/${local.name}/exec"
  retention_in_days = var.log_retention_days

  tags = { Name = "${local.name}-exec" }
}

resource "aws_cloudwatch_log_group" "flow_logs" {
  name              = "/vpc/${local.name}/rejects"
  retention_in_days = 14

  tags = { Name = "${local.name}-flow-logs" }
}

# --- Structured-log queries -------------------------------------------------
# The backend already emits one JSON object per line with a request id, so the
# fields below are queryable without any parsing rule. Saved here so the
# runbook can name a query instead of describing one.

resource "aws_cloudwatch_query_definition" "errors" {
  name = "${local.name}/backend-5xx"

  log_group_names = [aws_cloudwatch_log_group.backend.name]

  query_string = <<-QUERY
    fields @timestamp, request_id, http_method, http_path, http_status, duration_ms
    | filter http_status >= 500
    | sort @timestamp desc
    | limit 100
  QUERY
}

resource "aws_cloudwatch_query_definition" "trace_request" {
  name = "${local.name}/trace-request-id"

  log_group_names = [
    aws_cloudwatch_log_group.backend.name,
    aws_cloudwatch_log_group.frontend.name,
  ]

  query_string = <<-QUERY
    fields @timestamp, @logStream, @message
    | filter request_id = "PASTE_REQUEST_ID_HERE"
    | sort @timestamp asc
  QUERY
}

resource "aws_cloudwatch_query_definition" "slow_requests" {
  name = "${local.name}/backend-slow-requests"

  log_group_names = [aws_cloudwatch_log_group.backend.name]

  query_string = <<-QUERY
    fields @timestamp, http_method, http_route, http_status, duration_ms
    | filter duration_ms > 500
    | sort duration_ms desc
    | limit 100
  QUERY
}

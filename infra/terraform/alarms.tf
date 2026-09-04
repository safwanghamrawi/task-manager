################################################################################
# CloudWatch alarms.
#
# monitoring/alerts.yml holds the Prometheus rules that fired on the single
# host. Those still apply to the application's own metrics, but nothing is
# scraping them on Fargate yet (see the README on ADOT). These alarms cover
# the layer Prometheus never saw: the load balancer, the scheduler and the
# database.
#
# No SNS topic is created — where an alert should go is an organisational
# decision. Set `alarm_topic_arn` to wire them up; without it the alarms still
# evaluate and show state in the console.
################################################################################

locals {
  alarm_actions = var.alarm_topic_arn == "" ? [] : [var.alarm_topic_arn]
}

# --- Edge -------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "unhealthy_backend_targets" {
  alarm_name        = "${local.name}-backend-unhealthy-targets"
  alarm_description = "At least one backend task is failing /health/ready. One is a bad task; all of them is the database."

  namespace   = "AWS/ApplicationELB"
  metric_name = "UnHealthyHostCount"
  statistic   = "Maximum"
  period      = 60

  dimensions = {
    LoadBalancer = aws_lb.main.arn_suffix
    TargetGroup  = aws_lb_target_group.backend.arn_suffix
  }

  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  evaluation_periods  = 3
  # Missing data during a deployment is not a failure.
  treat_missing_data = "notBreaching"

  alarm_actions = local.alarm_actions
  ok_actions    = local.alarm_actions

  tags = { Name = "${local.name}-backend-unhealthy-targets" }
}

resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name        = "${local.name}-alb-5xx"
  alarm_description = "The load balancer itself is generating 5xx: no healthy target, or every target timing out."

  namespace   = "AWS/ApplicationELB"
  metric_name = "HTTPCode_ELB_5XX_Count"
  statistic   = "Sum"
  period      = 60

  dimensions = { LoadBalancer = aws_lb.main.arn_suffix }

  comparison_operator = "GreaterThanThreshold"
  threshold           = 5
  evaluation_periods  = 2
  treat_missing_data  = "notBreaching"

  alarm_actions = local.alarm_actions

  tags = { Name = "${local.name}-alb-5xx" }
}

resource "aws_cloudwatch_metric_alarm" "target_latency" {
  alarm_name        = "${local.name}-backend-latency"
  alarm_description = "p95 backend latency above 500ms — the threshold the k6 baseline in loadtest/ was measured against."

  namespace          = "AWS/ApplicationELB"
  metric_name        = "TargetResponseTime"
  extended_statistic = "p95"
  period             = 60

  dimensions = {
    LoadBalancer = aws_lb.main.arn_suffix
    TargetGroup  = aws_lb_target_group.backend.arn_suffix
  }

  comparison_operator = "GreaterThanThreshold"
  threshold           = 0.5
  evaluation_periods  = 5
  treat_missing_data  = "notBreaching"

  alarm_actions = local.alarm_actions

  tags = { Name = "${local.name}-backend-latency" }
}

# --- Scheduler --------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "backend_running_count" {
  alarm_name        = "${local.name}-backend-below-minimum"
  alarm_description = "Fewer backend tasks running than the autoscaling floor. Usually a task that cannot start: bad image, or a secret it cannot read."

  namespace   = "ECS/ContainerInsights"
  metric_name = "RunningTaskCount"
  statistic   = "Minimum"
  period      = 60

  dimensions = {
    ClusterName = aws_ecs_cluster.main.name
    ServiceName = aws_ecs_service.backend.name
  }

  comparison_operator = "LessThanThreshold"
  threshold           = var.backend_min_capacity
  evaluation_periods  = 5
  treat_missing_data  = "breaching"

  alarm_actions = local.alarm_actions

  tags = { Name = "${local.name}-backend-below-minimum" }
}

# --- Database ---------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "db_cpu" {
  alarm_name        = "${local.name}-db-cpu"
  alarm_description = "Sustained database CPU. On a burstable class this is the precursor to credit exhaustion."

  namespace   = "AWS/RDS"
  metric_name = "CPUUtilization"
  statistic   = "Average"
  period      = 300

  dimensions = { DBInstanceIdentifier = aws_db_instance.main.identifier }

  comparison_operator = "GreaterThanThreshold"
  threshold           = 80
  evaluation_periods  = 3
  treat_missing_data  = "notBreaching"

  alarm_actions = local.alarm_actions

  tags = { Name = "${local.name}-db-cpu" }
}

resource "aws_cloudwatch_metric_alarm" "db_storage" {
  alarm_name        = "${local.name}-db-storage"
  alarm_description = "Free storage below 4 GiB. Storage autoscaling should act first; this fires if it did not."

  namespace   = "AWS/RDS"
  metric_name = "FreeStorageSpace"
  statistic   = "Minimum"
  period      = 300

  dimensions = { DBInstanceIdentifier = aws_db_instance.main.identifier }

  comparison_operator = "LessThanThreshold"
  threshold           = 4 * 1024 * 1024 * 1024
  evaluation_periods  = 2
  treat_missing_data  = "notBreaching"

  alarm_actions = local.alarm_actions

  tags = { Name = "${local.name}-db-storage" }
}

resource "aws_cloudwatch_metric_alarm" "db_connections" {
  alarm_name        = "${local.name}-db-connections"
  alarm_description = "Connection count approaching what a db.t4g.micro allows. Each backend task holds db_pool_size + db_max_overflow."

  namespace   = "AWS/RDS"
  metric_name = "DatabaseConnections"
  statistic   = "Maximum"
  period      = 60

  dimensions = { DBInstanceIdentifier = aws_db_instance.main.identifier }

  comparison_operator = "GreaterThanThreshold"
  # 80% of what PostgreSQL will accept. The previous threshold was derived from
  # demand (tasks x pool), which put it ABOVE the instance's own ceiling — so it
  # could never fire before connections were already being refused. An alarm
  # has to sit below the wall it is warning about.
  threshold          = floor(var.db_max_connections * 0.8)
  evaluation_periods = 3
  treat_missing_data = "notBreaching"

  alarm_actions = local.alarm_actions

  tags = { Name = "${local.name}-db-connections" }
}

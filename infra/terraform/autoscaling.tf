################################################################################
# Service autoscaling.
#
# On the single host, scaling was `docker compose up -d --scale backend=3`,
# run by a human who had noticed. The ceiling was one machine's CPU and the
# response time was however long it took someone to look at a graph.
#
# Target tracking replaces both. Two policies per service, because CPU alone
# is the wrong signal for an I/O-bound API: a backend saturated on database
# latency sits at 30% CPU while its queue grows. Request count per target
# catches that; CPU catches a genuine compute spike. Whichever asks for more
# capacity wins.
################################################################################

resource "aws_appautoscaling_target" "backend" {
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.backend.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = var.backend_min_capacity
  max_capacity       = var.backend_max_capacity

  tags = { Name = "${local.name}-backend" }
}

resource "aws_appautoscaling_policy" "backend_cpu" {
  name               = "${local.name}-backend-cpu"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.backend.service_namespace
  resource_id        = aws_appautoscaling_target.backend.resource_id
  scalable_dimension = aws_appautoscaling_target.backend.scalable_dimension

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }

    target_value = 60
    # Scale out promptly, scale in slowly: adding a task that turns out to be
    # unnecessary costs cents, removing one that was needed costs latency.
    scale_out_cooldown = 60
    scale_in_cooldown  = 300
  }
}

resource "aws_appautoscaling_policy" "backend_requests" {
  name               = "${local.name}-backend-requests"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.backend.service_namespace
  resource_id        = aws_appautoscaling_target.backend.resource_id
  scalable_dimension = aws_appautoscaling_target.backend.scalable_dimension

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      # ALB and target group, in the ARN-suffix form this metric wants.
      resource_label = "${aws_lb.main.arn_suffix}/${aws_lb_target_group.backend.arn_suffix}"
    }

    # Sustained requests per minute per task. The k6 run in loadtest/ measured
    # what one replica absorbs before p95 moves; this sits comfortably under
    # it so scaling happens before latency is visible, not after.
    target_value       = 3000
    scale_out_cooldown = 60
    scale_in_cooldown  = 300
  }
}

resource "aws_appautoscaling_target" "frontend" {
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.frontend.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = var.frontend_min_capacity
  max_capacity       = var.frontend_max_capacity

  tags = { Name = "${local.name}-frontend" }
}

resource "aws_appautoscaling_policy" "frontend_cpu" {
  name               = "${local.name}-frontend-cpu"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.frontend.service_namespace
  resource_id        = aws_appautoscaling_target.frontend.resource_id
  scalable_dimension = aws_appautoscaling_target.frontend.scalable_dimension

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }

    target_value       = 65
    scale_out_cooldown = 60
    scale_in_cooldown  = 300
  }
}

################################################################################
# Everything the pipeline, the runbook and an operator need. `terraform output`
# is the source of truth for these values — nothing here should be copied into
# a second place where it can drift.
################################################################################

output "app_url" {
  description = "Public entry point. Feed this to scripts/smoke-test.sh."
  # Over HTTPS this MUST be the certificate's domain, not the load balancer's
  # own hostname: the certificate is issued for domain_name, so a request to
  # *.elb.amazonaws.com fails hostname verification before it is even served.
  value = (
    local.tls_enabled && var.domain_name != "" ? "https://${var.domain_name}" :
    local.tls_enabled ? "https://${aws_lb.main.dns_name}" :
    "http://${aws_lb.main.dns_name}"
  )
}

output "alb_dns_name" {
  description = "Load balancer hostname. Point a CNAME (or a Route 53 alias) here."
  value       = aws_lb.main.dns_name
}

output "alb_zone_id" {
  description = "Hosted zone of the load balancer, for a Route 53 alias record."
  value       = aws_lb.main.zone_id
}

output "aws_region" {
  description = "Region everything was created in."
  value       = local.region
}

output "ecs_cluster_name" {
  description = "ECS cluster name."
  value       = aws_ecs_cluster.main.name
}

output "backend_service_name" {
  description = "Backend ECS service name."
  value       = aws_ecs_service.backend.name
}

output "frontend_service_name" {
  description = "Frontend ECS service name."
  value       = aws_ecs_service.frontend.name
}

output "backend_task_family" {
  description = "Task definition family CI registers new revisions against."
  value       = aws_ecs_task_definition.backend.family
}

output "frontend_task_family" {
  description = "Task definition family CI registers new revisions against."
  value       = aws_ecs_task_definition.frontend.family
}

output "backend_repository_url" {
  description = "ECR repository to push the backend image to."
  value       = aws_ecr_repository.this["backend"].repository_url
}

output "frontend_repository_url" {
  description = "ECR repository to push the frontend image to."
  value       = aws_ecr_repository.this["frontend"].repository_url
}

output "ecr_registry" {
  description = "Registry host, for `docker login`."
  value       = "${local.account_id}.dkr.ecr.${local.region}.amazonaws.com"
}

output "github_deploy_role_arn" {
  description = "Role for the AWS_DEPLOY_ROLE_ARN repository variable. Empty when github_repository is not set."
  value       = local.github_enabled == 1 ? aws_iam_role.github_deploy[0].arn : ""
}

output "database_secret_arn" {
  description = "Secrets Manager secret holding the database credentials and URL."
  value       = aws_secretsmanager_secret.db.arn
}

output "database_endpoint" {
  description = "RDS endpoint. Only reachable from inside the VPC."
  value       = aws_db_instance.main.address
}

output "acm_certificate_arn" {
  description = "The certificate the HTTPS listener uses. Empty when running plain HTTP."
  value       = local.tls_enabled ? local.certificate_arn : ""
}

output "acm_validation_record" {
  description = <<-DESC
    The DNS record that proves domain ownership, for a zone Terraform does not
    manage. Add it at your provider, then apply again. Empty when Route 53
    handles it or when no certificate is being created.

    ACM re-reads this record to auto-renew — leave it in place permanently.
  DESC
  value = local.create_certificate == 1 && local.manage_validation == 0 ? {
    for dvo in flatten(aws_acm_certificate.main[*].domain_validation_options) :
    dvo.domain_name => {
      name  = dvo.resource_record_name
      type  = dvo.resource_record_type
      value = dvo.resource_record_value
    }
  } : {}
}

output "alb_arn" {
  description = "Load balancer ARN, for the elbv2 and wafv2 CLI calls in the runbook."
  value       = aws_lb.main.arn
}

output "backend_target_group_arn" {
  description = "Backend target group, for `aws elbv2 describe-target-health`."
  value       = aws_lb_target_group.backend.arn
}

output "frontend_target_group_arn" {
  description = "Frontend target group, for `aws elbv2 describe-target-health`."
  value       = aws_lb_target_group.frontend.arn
}

output "db_instance_identifier" {
  description = "RDS identifier, for the rds CLI calls in the runbook."
  value       = aws_db_instance.main.identifier
}

output "backend_log_group" {
  description = "CloudWatch log group for the backend."
  value       = aws_cloudwatch_log_group.backend.name
}

output "frontend_log_group" {
  description = "CloudWatch log group for the frontend."
  value       = aws_cloudwatch_log_group.frontend.name
}

# --- Convenience ------------------------------------------------------------

output "deploy_env" {
  description = <<-DESC
    Shell exports for scripts/ecs-deploy.sh and scripts/ecs-rollback.sh:

      eval "$(terraform -chdir=infra/terraform output -raw deploy_env)"
  DESC
  value = join("\n", [
    "export AWS_REGION=${local.region}",
    "export ECS_CLUSTER=${aws_ecs_cluster.main.name}",
    "export BACKEND_SERVICE=${aws_ecs_service.backend.name}",
    "export FRONTEND_SERVICE=${aws_ecs_service.frontend.name}",
    "export BACKEND_REPOSITORY=${aws_ecr_repository.this["backend"].repository_url}",
    "export FRONTEND_REPOSITORY=${aws_ecr_repository.this["frontend"].repository_url}",
    "export APP_URL=${local.tls_enabled && var.domain_name != "" ? "https://${var.domain_name}" : local.tls_enabled ? "https://${aws_lb.main.dns_name}" : "http://${aws_lb.main.dns_name}"}",
    # Not needed to deploy; needed constantly by docs/RUNBOOK.md.
    "export ALB_ARN=${aws_lb.main.arn}",
    "export BACKEND_TARGET_GROUP=${aws_lb_target_group.backend.arn}",
    "export FRONTEND_TARGET_GROUP=${aws_lb_target_group.frontend.arn}",
    "export DB_INSTANCE=${aws_db_instance.main.identifier}",
    "export BACKEND_LOG_GROUP=${aws_cloudwatch_log_group.backend.name}",
    "export FRONTEND_LOG_GROUP=${aws_cloudwatch_log_group.frontend.name}",
  ])
}

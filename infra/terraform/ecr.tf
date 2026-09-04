################################################################################
# Private image registry.
#
# ECR replaces Docker Hub for the deployed images: pulls are authorised by the
# task execution role, so there is no registry credential stored anywhere in
# the account, and no Docker Hub pull-rate limit between a scale-out event and
# a running task.
################################################################################

locals {
  repositories = {
    backend  = "${var.project}/backend"
    frontend = "${var.project}/frontend"
  }
}

resource "aws_ecr_repository" "this" {
  for_each = local.repositories

  name                 = each.value
  image_tag_mutability = "MUTABLE" # `latest` has to move; the SHA tags never do.
  force_delete         = false

  image_scanning_configuration {
    # Scan on push in addition to the Trivy gate in CI. Trivy blocks the
    # release; this catches a CVE published after the image already shipped.
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = { Name = "${local.name}-${each.key}" }
}

# Untagged layers accumulate on every rebuild and are billed by the GB.
# Tagged images are kept generously: a rollback target must still exist.
resource "aws_ecr_lifecycle_policy" "this" {
  for_each = aws_ecr_repository.this

  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after a day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep the 30 most recent commit-tagged images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["sha-"]
          countType     = "imageCountMoreThan"
          countNumber   = 30
        }
        action = { type = "expire" }
      },
    ]
  })
}

# Only this account's ECS may pull. The default is already account-private;
# this makes the intent explicit and survives someone widening it by accident.
resource "aws_ecr_repository_policy" "this" {
  for_each = aws_ecr_repository.this

  repository = each.value.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowEcsPull"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action = [
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:BatchCheckLayerAvailability",
      ]
      Condition = {
        StringEquals = { "aws:SourceAccount" = local.account_id }
      }
    }]
  })
}

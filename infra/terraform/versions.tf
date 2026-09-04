################################################################################
# Provider and state configuration.
#
# State stays local by default so `terraform init` works with no prerequisites.
# For anything shared, uncomment the S3 backend below and pass the location at
# init time — where state lives is an account-level decision, not a repository
# one:
#
#   terraform init \
#     -backend-config="bucket=my-tf-state" \
#     -backend-config="key=task-manager/production.tfstate" \
#     -backend-config="region=eu-west-1" \
#     -backend-config="use_lockfile=true"
#
# Either way the state file contains the generated database password. It is
# gitignored; keep it that way.
################################################################################

terraform {
  required_version = ">= 1.9.0"

  # backend "s3" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  name = "${var.project}-${var.environment}"

  # The cluster alone may be named independently of everything else; see
  # var.cluster_name for why that is sometimes worth doing.
  cluster_name = var.cluster_name != "" ? var.cluster_name : local.name

  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name

  # Two AZs is the minimum an ALB accepts and the minimum that makes a
  # rolling deployment survive losing one.
  azs = slice(var.availability_zones, 0, 2)

  # Target group names are capped at 32 characters and "-frontend" costs nine
  # of them. Truncate rather than fail an apply on a longer project name.
  tg_prefix = substr(local.name, 0, 22)

  # The valid Fargate cpu -> memory pairings, verbatim from the ECS docs. It is
  # a discrete set, not a range: 256 goes 512 -> 1024 -> 2048 with nothing in
  # between. Checked by preconditions on the task definitions in ecs.tf, so an
  # invalid pairing fails at plan time instead of surfacing as the unhelpful
  # "No Fargate configuration exists for given values" mid-apply.
  fargate_memory_for_cpu = {
    "256"   = [512, 1024, 2048]
    "512"   = [1024, 2048, 3072, 4096]
    "1024"  = [for gb in range(2, 9) : gb * 1024]
    "2048"  = [for gb in range(4, 17) : gb * 1024]
    "4096"  = [for gb in range(8, 31) : gb * 1024]
    "8192"  = [for gb in range(16, 61, 4) : gb * 1024]
    "16384" = [for gb in range(32, 121, 8) : gb * 1024]
  }
}

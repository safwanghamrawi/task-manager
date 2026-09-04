################################################################################
# Keyless CI: a role GitHub Actions assumes over OIDC.
#
# The EC2 pipeline held a long-lived SSH private key in a repository secret.
# The replacement holds nothing: GitHub mints a short-lived OIDC token for the
# workflow run, AWS exchanges it for credentials that expire in an hour, and
# the trust policy pins which repository and which ref may do so. There is no
# secret to leak, rotate, or forget to revoke when someone leaves.
#
# Set `github_repository` to "owner/repo" to create this. Leave it empty and
# nothing here exists.
################################################################################

locals {
  github_enabled = var.github_repository == "" ? 0 : 1

  create_oidc_provider = local.github_enabled == 1 && var.github_oidc_provider_arn == "" ? 1 : 0

  github_oidc_arn = local.github_enabled == 0 ? "" : (
    var.github_oidc_provider_arn != ""
    ? var.github_oidc_provider_arn
    : aws_iam_openid_connect_provider.github[0].arn
  )

  # --- Subject claims -------------------------------------------------------
  #
  # GitHub changed the shape of this claim. Repositories created after
  # 2026-07-15 get an *immutable* subject that embeds numeric owner and
  # repository IDs, delimited by "@":
  #
  #   repo:owner@3163835/name@1353555273:ref:refs/heads/main   (immutable)
  #   repo:owner/name:ref:refs/heads/main                      (legacy)
  #
  # The point of the change is that names can be renamed, transferred and
  # re-registered, so a policy trusting a name is exposed to someone later
  # claiming that name. IDs cannot be recycled.
  #
  # A trust policy written against the legacy shape silently matches nothing
  # on a new repository, and STS reports it as "Not authorized to perform
  # sts:AssumeRoleWithWebIdentity" — the same message as every other failure.
  github_owner = try(split("/", var.github_repository)[0], "")
  github_name  = try(split("/", var.github_repository)[1], "")

  # Pin the exact IDs when they are known. Falling back to "@*" keeps this
  # working with no configuration: the literal "owner@" prefix still has to
  # match, and an owner name is unique, so another account cannot satisfy it.
  github_immutable_repo = format(
    "%s@%s/%s@%s",
    local.github_owner,
    var.github_owner_id == "" ? "*" : var.github_owner_id,
    local.github_name,
    var.github_repository_id == "" ? "*" : var.github_repository_id,
  )

  # Which refs may assume the role, independent of the subject shape.
  github_subject_scopes = [
    "ref:refs/heads/main",
    "ref:refs/tags/v*",
    # Deployments are gated on the `production` GitHub environment, so a pull
    # request from a fork cannot reach this even if it could set the subject —
    # the environment's protection rules run first.
    "environment:production",
  ]

  github_subjects = concat(
    [for scope in local.github_subject_scopes : "repo:${local.github_immutable_repo}:${scope}"],
    # Only for repositories predating the change, which still issue name-based
    # subjects. Off by default: this is precisely the recyclable shape.
    var.github_trust_legacy_subject
    ? [for scope in local.github_subject_scopes : "repo:${var.github_repository}:${scope}"]
    : [],
  )
}

resource "aws_iam_openid_connect_provider" "github" {
  count = local.create_oidc_provider

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # Thumbprint verification is no longer used for this provider by IAM, but
  # the field is still required. This is GitHub's documented value.
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  tags = { Name = "${local.name}-github" }
}

data "aws_iam_policy_document" "github_assume" {
  count = local.github_enabled

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Pinned to this repository. `sub` is not a wildcard over the whole of
    # GitHub: without this condition any repository on github.com could assume
    # the role. See the locals above for why there are two shapes.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.github_subjects
    }
  }
}

resource "aws_iam_role" "github_deploy" {
  count = local.github_enabled

  name        = "${local.name}-github-deploy"
  description = "Assumed by GitHub Actions to push images and roll ECS services."

  assume_role_policy = data.aws_iam_policy_document.github_assume[0].json
  # An hour is longer than the pipeline needs and far shorter than a key lives.
  max_session_duration = 3600

  tags = { Name = "${local.name}-github-deploy" }
}

data "aws_iam_policy_document" "github_deploy" {
  count = local.github_enabled

  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # This action is account-scoped and takes no resource.
  }

  statement {
    sid = "EcrPush"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = [for repo in aws_ecr_repository.this : repo.arn]
  }

  # Registering a revision cannot be scoped to a family: the ARN of the thing
  # being created does not exist yet. Updating a service can be, and is.
  statement {
    sid = "RegisterTaskDefinitions"
    actions = [
      "ecs:RegisterTaskDefinition",
      "ecs:DescribeTaskDefinition",
      "ecs:ListTaskDefinitions",
    ]
    resources = ["*"]
  }

  statement {
    sid = "RollServices"
    actions = [
      "ecs:UpdateService",
      "ecs:DescribeServices",
    ]
    resources = [
      aws_ecs_service.backend.id,
      aws_ecs_service.frontend.id,
    ]
  }

  statement {
    sid       = "InspectTasks"
    actions   = ["ecs:DescribeTasks", "ecs:ListTasks"]
    resources = ["*"]

    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = [aws_ecs_cluster.main.arn]
    }
  }

  # iam:PassRole is the privilege escalation that matters here: without the
  # condition, permission to register a task definition is permission to run a
  # container as any role in the account. Restricted to the three roles this
  # stack owns, and only when ECS is the one being handed them.
  statement {
    sid     = "PassTaskRoles"
    actions = ["iam:PassRole"]
    resources = [
      aws_iam_role.execution.arn,
      aws_iam_role.backend_task.arn,
      aws_iam_role.frontend_task.arn,
    ]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }

  # Read-only, so a failed deployment can report which target went unhealthy
  # rather than just "timed out".
  statement {
    sid = "ReadLoadBalancerHealth"
    actions = [
      "elasticloadbalancing:DescribeTargetHealth",
      "elasticloadbalancing:DescribeTargetGroups",
      "elasticloadbalancing:DescribeLoadBalancers",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "github_deploy" {
  count = local.github_enabled

  name   = "deploy"
  role   = aws_iam_role.github_deploy[0].id
  policy = data.aws_iam_policy_document.github_deploy[0].json
}

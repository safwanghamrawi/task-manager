#!/usr/bin/env bash
#
# Deploy an image tag to the ECS services. Replaces scripts/remote-deploy.sh,
# which ran ON the EC2 box; this runs from anywhere with credentials, because
# there is no longer a box to run on.
#
# Kept in the repository rather than inline in the workflow for the same
# reason as before: deployment logic that can be reviewed, shellcheck-ed and
# run by hand during an incident is worth more than one that only exists
# inside a CI runner.
#
#   eval "$(terraform -chdir=infra/terraform output -raw deploy_env)"
#   IMAGE_TAG=sha-1a2b3c4 ./scripts/ecs-deploy.sh
#
# What it does, per service:
#   1. reads the task definition the service is running now
#   2. rewrites only the image, leaving every other field untouched
#   3. registers that as a new revision
#   4. points the service at it and waits for the rollout to stabilise
#
# Step 2 matters: the running task definition is the source of truth, so a
# deployment never silently reverts an environment variable or a secret ARN
# that Terraform set. CI owns the tag; Terraform owns everything else.
set -euo pipefail

IMAGE_TAG="${IMAGE_TAG:?IMAGE_TAG must be set to the tag to deploy}"
ECS_CLUSTER="${ECS_CLUSTER:?ECS_CLUSTER must be set}"
BACKEND_SERVICE="${BACKEND_SERVICE:?BACKEND_SERVICE must be set}"
FRONTEND_SERVICE="${FRONTEND_SERVICE:?FRONTEND_SERVICE must be set}"
BACKEND_REPOSITORY="${BACKEND_REPOSITORY:?BACKEND_REPOSITORY must be set}"
FRONTEND_REPOSITORY="${FRONTEND_REPOSITORY:?FRONTEND_REPOSITORY must be set}"

# Where the pre-deployment revisions are recorded so a rollback needs no API
# archaeology. The EC2 deployment used .env.deploy.previous for exactly this.
STATE_FILE="${STATE_FILE:-.ecs-deploy-previous}"
WAIT_TIMEOUT_SECONDS="${WAIT_TIMEOUT_SECONDS:-900}"

for tool in aws jq; do
  command -v "${tool}" >/dev/null || { echo "ERROR: ${tool} is required" >&2; exit 1; }
done

RENDERED="$(mktemp -t task-definition.XXXXXX)"
trap 'rm -f "${RENDERED}"' EXIT

log() { printf '==> %s\n' "$*"; }

# `timeout` is GNU coreutils and is not on a stock macOS. The waits below are
# a safety net, not the mechanism, so fall back to running without one rather
# than refusing to deploy from a laptop.
with_timeout() {
  local seconds="$1"; shift
  if command -v timeout >/dev/null; then
    timeout "${seconds}" "$@"
  else
    "$@"
  fi
}

# --- Helpers ----------------------------------------------------------------

current_task_definition() {
  aws ecs describe-services \
    --cluster "${ECS_CLUSTER}" \
    --services "$1" \
    --query 'services[0].taskDefinition' \
    --output text
}

# Register a copy of $1 with the image of container $2 set to $3, and echo the
# new revision's ARN.
register_with_image() {
  local task_definition_arn="$1" container="$2" image="$3"

  aws ecs describe-task-definition \
    --task-definition "${task_definition_arn}" \
    --query 'taskDefinition' \
    --output json \
  | jq --arg container "${container}" --arg image "${image}" '
      # Fields the API returns but refuses on the way back in.
      del(
        .taskDefinitionArn,
        .revision,
        .status,
        .requiresAttributes,
        .compatibilities,
        .registeredAt,
        .registeredBy,
        .deregisteredAt
      )
      | .containerDefinitions |= map(
          if .name == $container then .image = $image else . end
        )
    ' > "${RENDERED}"

  # Fail loudly if the container name did not match anything: a silent no-op
  # here would deploy the previous image and report success.
  jq -e --arg image "${image}" \
    'any(.containerDefinitions[]; .image == $image)' \
    "${RENDERED}" >/dev/null \
    || { echo "ERROR: no container named '${container}' in ${task_definition_arn}" >&2; exit 1; }

  aws ecs register-task-definition \
    --cli-input-json "file://${RENDERED}" \
    --query 'taskDefinition.taskDefinitionArn' \
    --output text
}

deploy_service() {
  local service="$1" container="$2" repository="$3"
  local image="${repository}:${IMAGE_TAG}"

  log "${service}: reading the running task definition"
  local previous
  previous="$(current_task_definition "${service}")"
  echo "${service} ${previous}" >> "${STATE_FILE}"
  log "${service}: currently ${previous##*/}"

  log "${service}: registering a revision with ${image}"
  local revision
  revision="$(register_with_image "${previous}" "${container}" "${image}")"
  log "${service}: registered ${revision##*/}"

  log "${service}: rolling out"
  # The backticks below are a JMESPath literal, not a shell substitution.
  # shellcheck disable=SC2016
  aws ecs update-service \
    --cluster "${ECS_CLUSTER}" \
    --service "${service}" \
    --task-definition "${revision}" \
    --no-cli-pager \
    --query 'service.deployments[?status==`PRIMARY`].[taskDefinition,desiredCount]' \
    --output text
}

wait_for_service() {
  local service="$1"

  log "${service}: waiting for the rollout to stabilise"
  # services-stable polls for up to 10 minutes on its own; the circuit breaker
  # configured in Terraform will have abandoned a bad revision well before it
  # gives up, so a timeout here means slow, not necessarily broken.
  if ! with_timeout "${WAIT_TIMEOUT_SECONDS}" aws ecs wait services-stable \
        --cluster "${ECS_CLUSTER}" \
        --services "${service}"; then
    echo "ERROR: ${service} did not stabilise" >&2
    describe_failure "${service}"
    return 1
  fi
  log "${service}: stable"
}

# Print why a rollout failed. A stopped Fargate task takes its filesystem with
# it, so `stoppedReason` plus the log group is the whole of the evidence.
describe_failure() {
  local service="$1"

  echo "--- deployments ---" >&2
  aws ecs describe-services \
    --cluster "${ECS_CLUSTER}" \
    --services "${service}" \
    --query 'services[0].deployments[].{status:status,desired:desiredCount,running:runningCount,failed:failedTasks,rollout:rolloutState,reason:rolloutStateReason}' \
    --output table >&2 || true

  echo "--- recent service events ---" >&2
  aws ecs describe-services \
    --cluster "${ECS_CLUSTER}" \
    --services "${service}" \
    --query 'services[0].events[:10].message' \
    --output text >&2 || true

  echo "--- stopped tasks ---" >&2
  local stopped
  stopped="$(aws ecs list-tasks \
    --cluster "${ECS_CLUSTER}" \
    --service-name "${service}" \
    --desired-status STOPPED \
    --query 'taskArns[:5]' \
    --output text 2>/dev/null || true)"

  if [[ -n "${stopped}" && "${stopped}" != "None" ]]; then
    # shellcheck disable=SC2086
    aws ecs describe-tasks \
      --cluster "${ECS_CLUSTER}" \
      --tasks ${stopped} \
      --query 'tasks[].{task:taskArn,stopped:stoppedReason,containers:containers[].{name:name,reason:reason,exit:exitCode}}' \
      --output json >&2 || true
  fi
}

# --- Deploy -----------------------------------------------------------------

: > "${STATE_FILE}"

log "Deploying ${IMAGE_TAG} to ${ECS_CLUSTER}"

# Backend first. The frontend is a static shell that degrades visibly rather
# than breaking when the API is briefly a mix of two revisions; the reverse
# order can serve a new UI against an API that has not caught up.
deploy_service "${BACKEND_SERVICE}" backend "${BACKEND_REPOSITORY}"
deploy_service "${FRONTEND_SERVICE}" frontend "${FRONTEND_REPOSITORY}"

# Both rollouts run concurrently; wait for them after starting both rather
# than serialising two 2-3 minute waits.
wait_for_service "${BACKEND_SERVICE}"
wait_for_service "${FRONTEND_SERVICE}"

log "Deployed ${IMAGE_TAG}"
aws ecs describe-services \
  --cluster "${ECS_CLUSTER}" \
  --services "${BACKEND_SERVICE}" "${FRONTEND_SERVICE}" \
  --query 'services[].{service:serviceName,taskDefinition:taskDefinition,desired:desiredCount,running:runningCount}' \
  --output table

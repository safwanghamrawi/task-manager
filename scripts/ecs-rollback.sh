#!/usr/bin/env bash
#
# Roll the ECS services back. Replaces scripts/remote-rollback.sh.
#
# There are three ways back, in descending order of preference:
#
#   1. .ecs-deploy-previous, written by ecs-deploy.sh before it changed
#      anything. Exact, and available in the same CI job that just failed.
#   2. The previous ACTIVE revision of each task definition family. Correct
#      whenever the last registration was the failed deployment.
#   3. An explicit revision or image tag passed as an argument.
#
# ECS's own deployment circuit breaker (enabled in Terraform) already reverts
# a revision whose tasks never reach a steady state. This script is for the
# other case: tasks that start, pass their health checks, and are wrong.
#
#   ./scripts/ecs-rollback.sh                      # whatever was running before
#   ./scripts/ecs-rollback.sh sha-1a2b3c4          # a specific image tag
#   ./scripts/ecs-rollback.sh --revision 41        # a specific revision number
set -euo pipefail

ECS_CLUSTER="${ECS_CLUSTER:?ECS_CLUSTER must be set}"
BACKEND_SERVICE="${BACKEND_SERVICE:?BACKEND_SERVICE must be set}"
FRONTEND_SERVICE="${FRONTEND_SERVICE:?FRONTEND_SERVICE must be set}"

STATE_FILE="${STATE_FILE:-.ecs-deploy-previous}"
WAIT_TIMEOUT_SECONDS="${WAIT_TIMEOUT_SECONDS:-900}"

for tool in aws jq; do
  command -v "${tool}" >/dev/null || { echo "ERROR: ${tool} is required" >&2; exit 1; }
done

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

target_tag=""
target_revision=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --revision) target_revision="${2:?--revision needs a number}"; shift 2 ;;
    -h|--help)  sed -n '2,30p' "$0"; exit 0 ;;
    *)          target_tag="$1"; shift ;;
  esac
done

# --- Resolving the target ---------------------------------------------------

family_of() {
  aws ecs describe-services \
    --cluster "${ECS_CLUSTER}" \
    --services "$1" \
    --query 'services[0].taskDefinition' \
    --output text \
  | sed 's#.*/##; s/:[0-9]*$//'
}

# The revision before the one the service is running now.
previous_revision_of() {
  local family="$1" current
  current="$(aws ecs describe-services \
    --cluster "${ECS_CLUSTER}" --services "$2" \
    --query 'services[0].taskDefinition' --output text)"

  aws ecs list-task-definitions \
    --family-prefix "${family}" \
    --status ACTIVE \
    --sort DESC \
    --max-items 10 \
    --query 'taskDefinitionArns' \
    --output json \
  | jq -r --arg current "${current}" '
      map(select(. != $current)) | .[0] // empty
    '
}

# Recorded by ecs-deploy.sh before it touched anything.
recorded_revision_of() {
  [[ -f "${STATE_FILE}" ]] || return 0
  awk -v service="$1" '$1 == service { print $2 }' "${STATE_FILE}" | tail -1
}

resolve_target() {
  local service="$1" family

  if [[ -n "${target_revision}" ]]; then
    family="$(family_of "${service}")"
    echo "${family}:${target_revision}"
    return
  fi

  if [[ -n "${target_tag}" ]]; then
    # Find the most recent revision whose container already carries that tag,
    # rather than registering a new one: rolling back should not create state.
    family="$(family_of "${service}")"
    local arns arn image
    arns="$(aws ecs list-task-definitions \
      --family-prefix "${family}" --status ACTIVE --sort DESC \
      --max-items 30 --query 'taskDefinitionArns' --output text)"

    for arn in ${arns}; do
      image="$(aws ecs describe-task-definition --task-definition "${arn}" \
        --query 'taskDefinition.containerDefinitions[0].image' --output text)"
      if [[ "${image##*:}" == "${target_tag}" ]]; then
        echo "${arn}"
        return
      fi
    done

    echo "ERROR: no ${family} revision runs image tag ${target_tag}" >&2
    exit 1
  fi

  local recorded
  recorded="$(recorded_revision_of "${service}")"
  if [[ -n "${recorded}" ]]; then
    echo "${recorded}"
    return
  fi

  family="$(family_of "${service}")"
  local previous
  previous="$(previous_revision_of "${family}" "${service}")"
  if [[ -z "${previous}" ]]; then
    echo "ERROR: no earlier revision of ${family} to roll back to" >&2
    exit 1
  fi
  echo "${previous}"
}

# --- Rolling back -----------------------------------------------------------

roll_back() {
  local service="$1" target
  target="$(resolve_target "${service}")"

  log "${service}: rolling back to ${target##*/}"
  aws ecs update-service \
    --cluster "${ECS_CLUSTER}" \
    --service "${service}" \
    --task-definition "${target}" \
    --no-cli-pager \
    --output text \
    --query 'service.serviceName' >/dev/null
}

roll_back "${BACKEND_SERVICE}"
roll_back "${FRONTEND_SERVICE}"

for service in "${BACKEND_SERVICE}" "${FRONTEND_SERVICE}"; do
  log "${service}: waiting for the rollback to stabilise"
  with_timeout "${WAIT_TIMEOUT_SECONDS}" aws ecs wait services-stable \
    --cluster "${ECS_CLUSTER}" --services "${service}" \
    || echo "WARNING: ${service} has not stabilised yet; check the console" >&2
done

log "Rolled back"
aws ecs describe-services \
  --cluster "${ECS_CLUSTER}" \
  --services "${BACKEND_SERVICE}" "${FRONTEND_SERVICE}" \
  --query 'services[].{service:serviceName,taskDefinition:taskDefinition,running:runningCount}' \
  --output table

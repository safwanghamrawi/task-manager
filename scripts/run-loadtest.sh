#!/usr/bin/env bash
#
# Run the k6 load test against a running stack.
#
# Uses the official k6 container so no local install is required, and joins the
# compose `edge` network so traffic goes through Traefik exactly as a real
# client's would.
#
#   ./scripts/run-loadtest.sh                            # through Traefik
#   BASE_URL=http://localhost:8080 ./scripts/run-loadtest.sh
#   VUS=200 DURATION=60s ./scripts/run-loadtest.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

BASE_URL="${BASE_URL:-http://traefik}"
VUS="${VUS:-100}"
DURATION="${DURATION:-30s}"
NETWORK="${NETWORK:-edge}"
RESULTS_DIR="loadtest/results"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

mkdir -p "${RESULTS_DIR}"

echo "==> Load test: ${VUS} VUs for ${DURATION} against ${BASE_URL}"

docker_args=(--rm -i -e "BASE_URL=${BASE_URL}" -e "VUS=${VUS}" -e "DURATION=${DURATION}")

# Only join the compose network when targeting a service name on it.
if [[ "${BASE_URL}" == *"//traefik"* || "${BASE_URL}" == *"//backend"* ]]; then
  docker_args+=(--network "${NETWORK}")
fi

docker run "${docker_args[@]}" \
  -v "${PWD}/loadtest:/scripts:ro" \
  -v "${PWD}/${RESULTS_DIR}:/results" \
  grafana/k6:latest run \
  --summary-export "/results/summary-${STAMP}.json" \
  /scripts/k6-load-test.js \
  | tee "${RESULTS_DIR}/run-${STAMP}.log"

echo
echo "==> Summary written to ${RESULTS_DIR}/summary-${STAMP}.json"
